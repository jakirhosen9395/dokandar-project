package com.dokandar.finance.api;

import com.dokandar.finance.app.EscrowService;
import com.dokandar.finance.app.IdemCommands;
import com.dokandar.finance.app.Views;
import com.dokandar.platform.Dto;
import com.fasterxml.jackson.databind.JsonNode;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/** Escrow REST surface (R3 saga endpoints). All writes require Idempotency-Key. */
@RestController
@RequestMapping("/v1/finance/escrows")
public class EscrowController {

    public record CreateEscrowReq(String referenceId, String referenceType, String buyerWlt,
                                  String sellerWlt, Long amountPoisha) {}
    public record ReleaseReq(String podEvidence) {}
    public record ReverseReq(String reason) {}

    private final EscrowService service;
    private final IdemCommands idem;

    public EscrowController(EscrowService service, IdemCommands idem) {
        this.service = service;
        this.idem = idem;
    }

    @PostMapping
    public ResponseEntity<Dto.Response<JsonNode>> create(
            @RequestHeader(value = "Idempotency-Key", required = false) String idemKey,
            @RequestBody CreateEscrowReq req) {
        return WalletController.respond(idem.run(idemKey, "POST /v1/finance/escrows", req, 201,
            () -> service.create(req.referenceId(), req.referenceType(), req.buyerWlt(), req.sellerWlt(),
                req.amountPoisha() == null ? 0 : req.amountPoisha())));
    }

    @PostMapping("/{esc}/release")
    public ResponseEntity<Dto.Response<JsonNode>> release(
            @RequestHeader(value = "Idempotency-Key", required = false) String idemKey,
            @PathVariable String esc, @RequestBody ReleaseReq req) {
        return WalletController.respond(idem.run(idemKey, "POST /v1/finance/escrows/" + esc + "/release", req, 200,
            () -> service.release(esc, req.podEvidence())));
    }

    @PostMapping("/{esc}/release-hold")
    public ResponseEntity<Dto.Response<JsonNode>> releaseHold(
            @RequestHeader(value = "Idempotency-Key", required = false) String idemKey,
            @PathVariable String esc) {
        return WalletController.respond(idem.run(idemKey,
            "POST /v1/finance/escrows/" + esc + "/release-hold", java.util.Map.of(), 200,
            () -> service.releaseHold(esc, false)));
    }

    @PostMapping("/{esc}/reverse")
    public ResponseEntity<Dto.Response<JsonNode>> reverse(
            @RequestHeader(value = "Idempotency-Key", required = false) String idemKey,
            @PathVariable String esc, @RequestBody ReverseReq req) {
        return WalletController.respond(idem.run(idemKey, "POST /v1/finance/escrows/" + esc + "/reverse", req, 200,
            () -> service.reverse(esc, req.reason())));
    }

    @GetMapping("/{esc}")
    public Dto.Response<Views.EscrowView> get(@PathVariable String esc) {
        return Dto.Response.ok(service.get(esc), null);
    }
}
