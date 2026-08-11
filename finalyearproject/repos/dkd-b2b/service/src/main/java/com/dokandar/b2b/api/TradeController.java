package com.dokandar.b2b.api;

import com.dokandar.b2b.app.IdemCommands;
import com.dokandar.b2b.app.TradeService;
import com.dokandar.b2b.app.Views;
import com.dokandar.b2b.domain.TradeStatus;
import com.dokandar.platform.Dto;
import com.fasterxml.jackson.databind.JsonNode;
import java.util.Map;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * TradeOrder REST surface. DM TradeOrder vocabulary (ADR-016 — the SA ch.10 RFQ/contract
 * routes have no spine topics and are errata). All writes require Idempotency-Key.
 */
@RestController
@RequestMapping("/v1/b2b/trades")
public class TradeController {

    public record MarginReq(Long amountPoisha) {}
    public record ReasonReq(String reason, String disputedBy) {}

    private final TradeService service;
    private final IdemCommands idem;
    private final com.fasterxml.jackson.databind.ObjectMapper mapper;

    public TradeController(TradeService service, IdemCommands idem,
                           com.fasterxml.jackson.databind.ObjectMapper mapper) {
        this.service = service;
        this.idem = idem;
        this.mapper = mapper;
    }

    @PostMapping
    public ResponseEntity<Dto.Response<JsonNode>> create(
            @RequestHeader(value = "Idempotency-Key", required = false) String idemKey,
            @RequestBody JsonNode body) {
        return respond(idem.runPrepared(idemKey, "POST /v1/b2b/trades", body, 201,
            () -> service.prepareCreate(body, idemKey),
            service::commitCreate));
    }

    /**
     * PostMargin, then ActivateTrade — the DM's "B2B domain service activates after
     * PostMargin processed". Activation runs after the margin transaction commits and is
     * self-healing: a replayed margin call re-attempts activation if the trade is still
     * MARGIN_POSTED, so a crash between the two steps never strands the aggregate.
     */
    @PostMapping("/{trd}/margin")
    public ResponseEntity<Dto.Response<JsonNode>> postMargin(
            @RequestHeader(value = "Idempotency-Key", required = false) String idemKey,
            @PathVariable String trd, @RequestBody MarginReq req) {
        IdemCommands.CmdResult r = idem.run(idemKey, "POST /v1/b2b/trades/" + trd + "/margin", req, 200,
            () -> service.postMargin(trd, req.amountPoisha() == null ? 0 : req.amountPoisha()));
        Views.TradeView current = service.get(trd);
        if (TradeStatus.valueOf(current.status()) == TradeStatus.MARGIN_POSTED)
            current = service.activate(trd);
        // The response reflects the CURRENT aggregate (usually ACTIVE) — the stored idem row
        // keeps the margin snapshot for conflict detection only (reviewer M-2).
        return ResponseEntity.status(r.status())
            .body(Dto.Response.ok(mapper.valueToTree(current),
                new Dto.Meta(null, null, Map.of("replayed", r.replayed()))));
    }

    /** Recovery command: idempotently drive MARGIN_POSTED -> ACTIVE. */
    @PostMapping("/{trd}/activate")
    public ResponseEntity<Dto.Response<JsonNode>> activate(
            @RequestHeader(value = "Idempotency-Key", required = false) String idemKey,
            @PathVariable String trd) {
        return respond(idem.run(idemKey, "POST /v1/b2b/trades/" + trd + "/activate", Map.of(), 200,
            () -> service.activate(trd)));
    }

    @PostMapping("/{trd}/initiate-settlement")
    public ResponseEntity<Dto.Response<JsonNode>> initiateSettlement(
            @RequestHeader(value = "Idempotency-Key", required = false) String idemKey,
            @PathVariable String trd, @RequestBody JsonNode body) {
        return respond(idem.runPrepared(idemKey, "POST /v1/b2b/trades/" + trd + "/initiate-settlement",
            body, 200,
            () -> service.prepareSettlement(trd, body.get("ppids")),
            ppids -> service.commitSettlement(trd, ppids)));
    }

    @PostMapping("/{trd}/dispute")
    public ResponseEntity<Dto.Response<JsonNode>> dispute(
            @RequestHeader(value = "Idempotency-Key", required = false) String idemKey,
            @PathVariable String trd, @RequestBody ReasonReq req) {
        return respond(idem.run(idemKey, "POST /v1/b2b/trades/" + trd + "/dispute", req, 200,
            () -> service.dispute(trd, req.reason(), req.disputedBy())));
    }

    @PostMapping("/{trd}/cancel")
    public ResponseEntity<Dto.Response<JsonNode>> cancel(
            @RequestHeader(value = "Idempotency-Key", required = false) String idemKey,
            @PathVariable String trd, @RequestBody ReasonReq req) {
        IdemCommands.CmdResult r = idem.run(idemKey, "POST /v1/b2b/trades/" + trd + "/cancel", req, 200,
            () -> service.cancel(trd, req.reason()));
        if (!r.replayed()) service.settleTradeReservations(trd, false); // post-commit compensation
        return respond(r);
    }

    @GetMapping("/{trd}")
    public Dto.Response<Views.TradeView> get(@PathVariable String trd) {
        return Dto.Response.ok(service.get(trd), null);
    }

    static ResponseEntity<Dto.Response<JsonNode>> respond(IdemCommands.CmdResult r) {
        return ResponseEntity.status(r.status())
            .body(Dto.Response.ok(r.body(), new Dto.Meta(null, null, Map.of("replayed", r.replayed()))));
    }
}
