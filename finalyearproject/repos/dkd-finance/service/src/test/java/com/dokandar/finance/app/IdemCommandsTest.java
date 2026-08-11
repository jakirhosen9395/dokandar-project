package com.dokandar.finance.app;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.dokandar.finance.store.IdemStore;
import com.dokandar.platform.Errors;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.atomic.AtomicInteger;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.TransactionStatus;
import org.springframework.transaction.support.SimpleTransactionStatus;
import org.springframework.transaction.support.TransactionTemplate;

class IdemCommandsTest {

    private IdemStore idemStore;
    private IdemCommands commands;

    @BeforeEach
    void setUp() {
        idemStore = mock(IdemStore.class);
        PlatformTransactionManager noopTx = new PlatformTransactionManager() {
            @Override public TransactionStatus getTransaction(TransactionDefinition d) { return new SimpleTransactionStatus(); }
            @Override public void commit(TransactionStatus s) {}
            @Override public void rollback(TransactionStatus s) {}
        };
        commands = new IdemCommands(idemStore, new TransactionTemplate(noopTx), new ObjectMapper());
    }

    @Test
    void missingIdempotencyKeyIsRejected() {
        assertThrows(Errors.ValidationException.class,
            () -> commands.run(null, "POST /x", Map.of(), 200, () -> "r"));
        assertThrows(Errors.ValidationException.class,
            () -> commands.run("  ", "POST /x", Map.of(), 200, () -> "r"));
    }

    @Test
    void freshKeyExecutesActionAndStoresResponse() {
        when(idemStore.find("k1", "POST /x")).thenReturn(Optional.empty());
        AtomicInteger runs = new AtomicInteger();
        var result = commands.run("k1", "POST /x", Map.of("a", 1), 201,
            () -> { runs.incrementAndGet(); return Map.of("wlt", "WLT-1"); });
        assertEquals(1, runs.get());
        assertEquals(201, result.status());
        assertFalse(result.replayed());
        assertEquals("WLT-1", result.body().get("wlt").asText());
        verify(idemStore).insert(eq("k1"), eq("POST /x"), anyString(), eq(201), anyString(), anyLong());
    }

    @Test
    void sameKeySameBodyReplaysStoredResponseWithoutRunningAction() throws Exception {
        String bodyJson = new ObjectMapper().writeValueAsString(Map.of("a", 1));
        String hash = storedHashFor(bodyJson);
        when(idemStore.find("k1", "POST /x")).thenReturn(Optional.of(
            new IdemStore.StoredResponse(hash, 201, "{\"wlt\":\"WLT-1\"}")));
        AtomicInteger runs = new AtomicInteger();
        var result = commands.run("k1", "POST /x", Map.of("a", 1), 201,
            () -> { runs.incrementAndGet(); return "never"; });
        assertEquals(0, runs.get());
        assertTrue(result.replayed());
        assertEquals(201, result.status());
        verify(idemStore, never()).insert(anyString(), anyString(), anyString(), anyInt(), anyString(), anyLong());
    }

    @Test
    void businessRejectionIsStoredAndRethrown() {
        when(idemStore.find("k9", "POST /x")).thenReturn(Optional.empty());
        var thrown = assertThrows(Errors.BusinessException.class,
            () -> commands.run("k9", "POST /x", Map.of("a", 1), 200, () -> {
                throw new Errors.BusinessException("dokandar.finance.wallet.insufficient_withdrawable", "no funds");
            }));
        assertEquals(409, thrown.httpStatus);
        // the rejection outcome is persisted so a retry replays it instead of re-executing
        verify(idemStore).insert(eq("k9"), eq("POST /x"), anyString(), eq(409),
            org.mockito.ArgumentMatchers.contains("__error"), anyLong());
    }

    @Test
    void storedBusinessRejectionReplaysAsTheSameError() throws Exception {
        String bodyJson = new ObjectMapper().writeValueAsString(Map.of("a", 1));
        when(idemStore.find("k9", "POST /x")).thenReturn(Optional.of(new IdemStore.StoredResponse(
            storedHashFor(bodyJson), 409,
            "{\"__error\":{\"code\":\"dokandar.finance.wallet.insufficient_withdrawable\",\"message\":\"no funds\"}}")));
        var thrown = assertThrows(Errors.DokandarException.class,
            () -> commands.run("k9", "POST /x", Map.of("a", 1), 200, () -> "never"));
        assertEquals(409, thrown.httpStatus);
        assertTrue(thrown.code.contains("insufficient_withdrawable"));
    }

    @Test
    void sameKeyDifferentBodyIsConflict() {
        when(idemStore.find(eq("k1"), anyString())).thenReturn(Optional.of(
            new IdemStore.StoredResponse("some-other-hash", 201, "{}")));
        var e = assertThrows(Errors.BusinessException.class,
            () -> commands.run("k1", "POST /x", Map.of("a", 2), 201, () -> "r"));
        assertTrue(e.code.contains("idempotency_key_reuse"));
    }

    private String storedHashFor(String json) throws Exception {
        var md = java.security.MessageDigest.getInstance("SHA-256");
        return java.util.HexFormat.of().formatHex(md.digest(json.getBytes(java.nio.charset.StandardCharsets.UTF_8)));
    }
}
