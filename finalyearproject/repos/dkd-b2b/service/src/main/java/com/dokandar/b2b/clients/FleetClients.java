package com.dokandar.b2b.clients;

import com.dokandar.platform.Errors;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.IOException;
import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

import io.grpc.ManagedChannel;
import io.grpc.ManagedChannelBuilder;
import io.grpc.StatusRuntimeException;
import java.util.concurrent.TimeUnit;
import com.dokandar.custody.ohs.v1.CustodyPassportOhsGrpc;
import com.dokandar.custody.ohs.v1.GetPassportRequest;
import com.dokandar.custody.ohs.v1.PassportReply;
import com.dokandar.inventory.ohs.v1.InventoryReservationOhsGrpc;
import com.dokandar.inventory.ohs.v1.ReserveRequest;
import com.dokandar.inventory.ohs.v1.ReserveReply;
import com.dokandar.inventory.ohs.v1.TransitionRequest;
import com.dokandar.inventory.ohs.v1.TransitionReply;

import com.dokandar.b2b.config.B2bProps;

/**
 * Outbound REST seams. BOTH calls happen in the PREPARE phase of a command — before the
 * DB transaction opens — so no pool connection is ever pinned across HTTP (fleet lesson,
 * b2c reviewer HIGH). Finance is NEVER called synchronously (R2/ADR-004: events only).
 *
 * - Inventory: G2 strong-local Reserve/Release (BR-024 margin-relevant reads hit strong
 *   local stock, never the eventual NIL rollup).
 * - Custody: read-only passport lookup used to VERIFY the InitiateSettlement precondition
 *   ("custody transferred, verified against Custody OHS by caller") — b2b never writes
 *   custody (R1).
 */
@Component
public class FleetClients {
    private static final Logger log = LoggerFactory.getLogger(FleetClients.class);
    private static final Duration TIMEOUT = Duration.ofSeconds(8);

    private final HttpClient http = HttpClient.newBuilder().connectTimeout(TIMEOUT).build();
    private final ObjectMapper mapper;
    private final B2bProps props;
    private final CustodyPassportOhsGrpc.CustodyPassportOhsBlockingStub passportStub; // B2B-F2: gRPC OHS, null => REST
    private final InventoryReservationOhsGrpc.InventoryReservationOhsBlockingStub inventoryStub; // B2B-F2

    public FleetClients(ObjectMapper mapper, B2bProps props) {
        this.mapper = mapper;
        this.props = props;
        // B2B-F2: prefer the gRPC internal plane (EF-API-1) when a custody gRPC target is configured.
        if (props.custodyGrpcUrl() != null && !props.custodyGrpcUrl().isBlank()) {
            ManagedChannel ch = ManagedChannelBuilder.forTarget(props.custodyGrpcUrl()).usePlaintext().build();
            this.passportStub = CustodyPassportOhsGrpc.newBlockingStub(ch);
        } else {
            this.passportStub = null;
        }
        if (props.inventoryGrpcUrl() != null && !props.inventoryGrpcUrl().isBlank()) {
            ManagedChannel ich = ManagedChannelBuilder.forTarget(props.inventoryGrpcUrl()).usePlaintext().build();
            this.inventoryStub = InventoryReservationOhsGrpc.newBlockingStub(ich);
        } else {
            this.inventoryStub = null;
        }
    }

    public boolean inventoryEnabled() { return !props.inventoryUrl().isBlank(); }
    public boolean custodyEnabled() { return !props.custodyUrl().isBlank(); }

    /** Reserve strong-local stock; returns the reservation id. 409 = insufficient stock (business-final). */
    public String reserve(String idemKey, String gpid, String holderDid, long quantity) {
        if (inventoryStub != null) return reserveViaGrpc(idemKey, gpid, holderDid, quantity);
        String body;
        try {
            body = mapper.writeValueAsString(java.util.Map.of(
                "gpid", gpid, "holder", holderDid, "quantity", quantity));
        } catch (IOException e) {
            throw new IllegalStateException(e);
        }
        HttpResponse<String> res = send(HttpRequest.newBuilder()
            .uri(URI.create(props.inventoryUrl() + "/v1/inventory/reservations"))
            .timeout(TIMEOUT)
            .header("Content-Type", "application/json")
            .header("Idempotency-Key", idemKey)
            .POST(HttpRequest.BodyPublishers.ofString(body)).build(), "inventory reserve");
        if (res.statusCode() == 200 || res.statusCode() == 201) {
            JsonNode data = parse(res.body()).path("data");
            String resId = data.path("resId").asText(null);
            if (resId == null)
                throw new Errors.DokandarException(
                    Errors.errorCode("b2b", "inventory", "bad_response"),
                    "reservation response had no resId", 502, null);
            return resId;
        }
        if (res.statusCode() == 409)
            throw new Errors.BusinessException(
                Errors.errorCode("b2b", "trade", "insufficient_stock"),
                "strong-local stock below requested quantity for " + gpid);
        throw unavailable("inventory", res.statusCode());
    }

    /** Release a reservation (compensation for a failed create). Best-effort, idempotent server-side. */
    public void release(String resId) {
        settle(resId, "release");
    }

    /** Confirm (consume) a reservation once the traded lot has custody-transferred. */
    public void confirm(String resId) {
        settle(resId, "confirm");
    }

    private void settle(String resId, String action) {
        if (inventoryStub != null) { settleViaGrpc(resId, action); return; }
        try {
            send(HttpRequest.newBuilder()
                .uri(URI.create(props.inventoryUrl() + "/v1/inventory/reservations/"
                    + URLEncoder.encode(resId, StandardCharsets.UTF_8) + "/" + action))
                .timeout(TIMEOUT)
                .header("Content-Type", "application/json")
                .POST(HttpRequest.BodyPublishers.ofString("{}")).build(), "inventory " + action);
        } catch (Errors.DokandarException e) {
            // Best-effort by contract (replays hit already-settled reservations), but NEVER
            // silent: an unreachable inventory here means a leaked hold to reconcile (M-3).
            log.warn("inventory {} for {} failed ({}): {}", action, resId, e.code, e.getMessage());
        }
    }

    public record Passport(String ppid, String gpid, String currentHolder) {}

    /** Read a custody passport (verification read — never a write, R1). B2B-F2: gRPC when configured. */
    public Passport passport(String ppid) {
        if (passportStub != null) return passportViaGrpc(ppid);
        HttpResponse<String> res = send(HttpRequest.newBuilder()
            .uri(URI.create(props.custodyUrl() + "/v1/custody/passports/"
                + URLEncoder.encode(ppid, StandardCharsets.UTF_8)))
            .timeout(TIMEOUT).GET().build(), "custody passport");
        if (res.statusCode() == 404)
            throw new Errors.BusinessException(
                Errors.errorCode("b2b", "trade", "unknown_ppid"),
                "custody has no passport " + ppid);
        if (res.statusCode() != 200) throw unavailable("custody", res.statusCode());
        JsonNode data = parse(res.body()).path("data");
        return new Passport(
            first(data, "PPID", "ppid"), first(data, "GPID", "gpid"),
            first(data, "CurrentHolder", "currentHolder"));
    }

    // B2B-F2: reserve G2 strong-local stock over the gRPC internal plane (inventory OHS).
    private String reserveViaGrpc(String idemKey, String gpid, String holderDid, long quantity) {
        try {
            ReserveReply r = inventoryStub.withDeadlineAfter(8, TimeUnit.SECONDS)
                .reserve(ReserveRequest.newBuilder().setIdempotencyKey(idemKey).setGpid(gpid)
                    .setHolder(holderDid).setQuantity(quantity).build());
            if (r.getInsufficientStock())
                throw new Errors.BusinessException(
                    Errors.errorCode("b2b", "trade", "insufficient_stock"),
                    "strong-local stock below requested quantity for " + gpid);
            if (!r.getOk() || r.getResId().isEmpty())
                throw new Errors.DokandarException(
                    Errors.errorCode("b2b", "inventory", "bad_response"), "reservation had no resId", 502, null);
            return r.getResId();
        } catch (StatusRuntimeException e) {
            throw new Errors.DokandarException(
                Errors.errorCode("b2b", "infrastructure", "upstream_unreachable"),
                "inventory gRPC unreachable: " + e.getMessage(), 503, null);
        }
    }

    // B2B-F2: release/confirm a reservation over gRPC (RELEASED | CONSUMED).
    private void settleViaGrpc(String resId, String action) {
        String to = action.equals("release") ? "RELEASED" : "CONSUMED";
        try {
            inventoryStub.withDeadlineAfter(8, TimeUnit.SECONDS)
                .transition(TransitionRequest.newBuilder().setResId(resId).setTo(to).build());
        } catch (StatusRuntimeException e) {
            log.warn("inventory gRPC {} for {} failed: {}", action, resId, e.getMessage());
        }
    }

    // B2B-F2: the EF-API-1 internal-plane path — resolve the passport head over gRPC (custody OHS).
    private Passport passportViaGrpc(String ppid) {
        try {
            PassportReply r = passportStub.withDeadlineAfter(8, TimeUnit.SECONDS)
                .getPassport(GetPassportRequest.newBuilder().setPpid(ppid).build());
            if (!r.getFound())
                throw new Errors.BusinessException(
                    Errors.errorCode("b2b", "trade", "unknown_ppid"), "custody has no passport " + ppid);
            return new Passport(r.getPpid(), r.getGpid(), r.getCurrentHolder());
        } catch (StatusRuntimeException e) {
            throw new Errors.DokandarException(
                Errors.errorCode("b2b", "infrastructure", "upstream_unreachable"),
                "custody gRPC unreachable: " + e.getMessage(), 503, null);
        }
    }

    private HttpResponse<String> send(HttpRequest req, String what) {
        try {
            return http.send(req, HttpResponse.BodyHandlers.ofString());
        } catch (IOException e) {
            throw new Errors.DokandarException(
                Errors.errorCode("b2b", "infrastructure", "upstream_unreachable"),
                what + " unreachable: " + e.getMessage(), 503, null);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new Errors.DokandarException(
                Errors.errorCode("b2b", "infrastructure", "interrupted"),
                what + " interrupted", 503, null);
        }
    }

    private Errors.DokandarException unavailable(String what, int status) {
        return new Errors.DokandarException(
            Errors.errorCode("b2b", "infrastructure", what + "_unavailable"),
            what + " returned status " + status, 503, null);
    }

    private JsonNode parse(String body) {
        try {
            return mapper.readTree(body == null ? "{}" : body);
        } catch (IOException e) {
            return mapper.createObjectNode();
        }
    }

    private static String first(JsonNode n, String... names) {
        for (String name : names) {
            JsonNode v = n.get(name);
            if (v != null && v.isTextual() && !v.asText().isBlank()) return v.asText();
        }
        return null;
    }

}
