package com.dokandar.finance.app;

import com.dokandar.finance.store.IdemStore;
import com.dokandar.platform.Errors;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;
import java.util.function.Supplier;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.stereotype.Component;
import org.springframework.transaction.support.TransactionTemplate;

/**
 * Exactly-once REST commands: the command body and the stored response commit in ONE
 * transaction keyed (Idempotency-Key, endpoint). Replays with the same request hash get
 * the stored response; a reused key with a different body is a 409. A concurrent
 * duplicate loses the PK race, its transaction rolls back, and it replays the winner.
 */
@Component
public class IdemCommands {

    public record CmdResult(int status, JsonNode body, boolean replayed) {}

    private final IdemStore idemStore;
    private final TransactionTemplate tx;
    private final ObjectMapper mapper;

    public IdemCommands(IdemStore idemStore, TransactionTemplate tx, ObjectMapper mapper) {
        this.idemStore = idemStore;
        this.tx = tx;
        this.mapper = mapper;
    }

    public CmdResult run(String idemKey, String endpoint, Object requestBody, int successStatus, Supplier<?> action) {
        if (idemKey == null || idemKey.isBlank())
            throw new Errors.ValidationException(
                Errors.errorCode("finance", "request", "missing_idempotency_key"),
                "Idempotency-Key header is mandatory on finance writes");
        String hash = sha256(toJson(requestBody));
        var existing = idemStore.find(idemKey, endpoint);
        if (existing.isPresent()) return replay(existing.get(), hash);
        try {
            return tx.execute(status -> {
                Object result = action.get();
                String body = toJson(result);
                idemStore.insert(idemKey, endpoint, hash, successStatus, body, System.currentTimeMillis());
                return new CmdResult(successStatus, parse(body), false);
            });
        } catch (DuplicateKeyException race) {
            var winner = idemStore.find(idemKey, endpoint).orElseThrow(() -> race);
            return replay(winner, hash);
        } catch (Errors.DokandarException businessFinal) {
            // Same key must always yield the same outcome: persist the business rejection in a
            // fresh transaction (the command tx already rolled back) so a retry replays it
            // instead of re-executing against possibly-changed state (reviewer MEDIUM).
            storeFailure(idemKey, endpoint, hash, businessFinal);
            throw businessFinal;
        }
    }

    private void storeFailure(String idemKey, String endpoint, String hash, Errors.DokandarException e) {
        String body = toJson(java.util.Map.of("__error",
            java.util.Map.of("code", e.code, "message", e.getMessage() == null ? "" : e.getMessage())));
        try {
            tx.executeWithoutResult(status ->
                idemStore.insert(idemKey, endpoint, hash, e.httpStatus, body, System.currentTimeMillis()));
        } catch (DuplicateKeyException lostRace) {
            // another attempt already recorded an outcome for this key — keep theirs
        }
    }

    private CmdResult replay(IdemStore.StoredResponse stored, String hash) {
        if (!stored.requestHash().equals(hash))
            throw new Errors.BusinessException(
                Errors.errorCode("finance", "request", "idempotency_key_reuse"),
                "Idempotency-Key was already used with a different request body");
        JsonNode body = parse(stored.bodyJson());
        if (body.has("__error")) {
            JsonNode err = body.get("__error");
            throw new Errors.DokandarException(err.get("code").asText(),
                err.get("message").asText(), stored.status(), null);
        }
        return new CmdResult(stored.status(), body, true);
    }

    private String toJson(Object o) {
        try {
            return mapper.writeValueAsString(o);
        } catch (JsonProcessingException e) {
            throw new IllegalStateException("request/response serialization failed", e);
        }
    }

    private JsonNode parse(String json) {
        try {
            return mapper.readTree(json);
        } catch (JsonProcessingException e) {
            throw new IllegalStateException("stored idempotent response is not valid JSON", e);
        }
    }

    private static String sha256(String s) {
        try {
            return HexFormat.of().formatHex(
                MessageDigest.getInstance("SHA-256").digest(s.getBytes(StandardCharsets.UTF_8)));
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
    }
}
