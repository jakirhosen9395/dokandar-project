package com.dokandar.finance.api;

import com.dokandar.finance.app.IdemCommands;
import com.dokandar.finance.app.Views;
import com.dokandar.finance.app.WalletService;
import com.dokandar.platform.Dto;
import com.fasterxml.jackson.databind.JsonNode;
import java.util.List;
import java.util.Map;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/** Wallet REST surface. Money JSON is integer poisha only; floats are rejected by Jackson config. */
@RestController
@RequestMapping("/v1/finance")
public class WalletController {

    public record CreateWalletReq(String ownerDid) {}
    public record MoneyReq(Long amountPoisha, String referenceId, String referenceType, Boolean isWithdrawable) {}
    public record FreezeReq(String reason, String freezeRef) {}
    public record MfsRegisterReq(String provider, String mobile, String accountName) {}
    public record MfsVerifyReq(String otpToken) {}

    private final WalletService service;
    private final IdemCommands idem;

    public WalletController(WalletService service, IdemCommands idem) {
        this.service = service;
        this.idem = idem;
    }

    @PostMapping("/wallets")
    public ResponseEntity<Dto.Response<JsonNode>> create(
            @RequestHeader(value = "Idempotency-Key", required = false) String idemKey,
            @RequestBody CreateWalletReq req) {
        return respond(idem.run(idemKey, "POST /v1/finance/wallets", req, 201,
            () -> service.create(req.ownerDid())));
    }

    @PostMapping("/wallets/{wlt}/credit")
    public ResponseEntity<Dto.Response<JsonNode>> credit(
            @RequestHeader(value = "Idempotency-Key", required = false) String idemKey,
            @PathVariable String wlt, @RequestBody MoneyReq req) {
        return respond(idem.run(idemKey, "POST /v1/finance/wallets/" + wlt + "/credit", req, 200,
            () -> service.credit(wlt, req.amountPoisha() == null ? 0 : req.amountPoisha(),
                req.referenceId(), req.referenceType(), req.isWithdrawable())));
    }

    @PostMapping("/wallets/{wlt}/debit")
    public ResponseEntity<Dto.Response<JsonNode>> debit(
            @RequestHeader(value = "Idempotency-Key", required = false) String idemKey,
            @PathVariable String wlt, @RequestBody MoneyReq req) {
        return respond(idem.run(idemKey, "POST /v1/finance/wallets/" + wlt + "/debit", req, 200,
            () -> service.debit(wlt, req.amountPoisha() == null ? 0 : req.amountPoisha(),
                req.referenceId(), req.referenceType())));
    }

    @PostMapping("/wallets/{wlt}/freeze")
    public ResponseEntity<Dto.Response<JsonNode>> freeze(
            @RequestHeader(value = "Idempotency-Key", required = false) String idemKey,
            @PathVariable String wlt, @RequestBody FreezeReq req) {
        return respond(idem.run(idemKey, "POST /v1/finance/wallets/" + wlt + "/freeze", req, 200,
            () -> service.freeze(wlt, req.reason(), req.freezeRef())));
    }

    @PostMapping("/wallets/{wlt}/mfs-accounts")
    public ResponseEntity<Dto.Response<JsonNode>> registerMfs(
            @RequestHeader(value = "Idempotency-Key", required = false) String idemKey,
            @PathVariable String wlt, @RequestBody MfsRegisterReq req) {
        return respond(idem.run(idemKey, "POST /v1/finance/wallets/" + wlt + "/mfs-accounts", req, 201,
            () -> service.registerMfs(wlt, req.provider(), req.mobile(), req.accountName())));
    }

    @PostMapping("/wallets/{wlt}/mfs-accounts/{mfsId}/verify")
    public ResponseEntity<Dto.Response<JsonNode>> verifyMfs(
            @RequestHeader(value = "Idempotency-Key", required = false) String idemKey,
            @PathVariable String wlt, @PathVariable String mfsId, @RequestBody MfsVerifyReq req) {
        return respond(idem.run(idemKey,
            "POST /v1/finance/wallets/" + wlt + "/mfs-accounts/" + mfsId + "/verify", req, 200,
            () -> service.verifyMfs(wlt, mfsId, req.otpToken())));
    }

    @GetMapping("/wallets/{wlt}")
    public Dto.Response<Views.WalletView> get(@PathVariable String wlt) {
        return Dto.Response.ok(service.get(wlt), null);
    }

    @GetMapping("/wallets/by-did/{did}")
    public Dto.Response<Views.WalletView> getByDid(@PathVariable String did) {
        return Dto.Response.ok(service.getByDid(did), null);
    }

    // F-13: opaque keyset-cursor pagination (?after=<lastId>) + populated meta (page + requestId/timestamp).
    @GetMapping("/wallets/{wlt}/ledger")
    public Dto.Response<List<Views.LedgerEntryView>> ledger(@PathVariable String wlt,
            @RequestParam(defaultValue = "50") int limit,
            @RequestParam(defaultValue = "0") long after) {
        WalletService.LedgerPage page = service.ledgerPage(wlt, after, limit);
        Dto.Meta meta = new Dto.Meta(
            new Dto.PageMeta(page.nextCursor(), page.hasMore(), page.limit()), null,
            Map.of("requestId", java.util.UUID.randomUUID().toString(), "timestamp", System.currentTimeMillis()));
        return Dto.Response.ok(page.entries(), meta);
    }

    /** Live double-entry invariant probe: every txn's signed legs must sum to zero. */
    @GetMapping("/ledger/integrity")
    public Dto.Response<Views.IntegrityView> integrity() {
        return Dto.Response.ok(service.integrity(), null);
    }

    static ResponseEntity<Dto.Response<JsonNode>> respond(IdemCommands.CmdResult r) {
        return ResponseEntity.status(r.status())
            .body(Dto.Response.ok(r.body(), new Dto.Meta(null, null, Map.of("replayed", r.replayed()))));
    }
}
