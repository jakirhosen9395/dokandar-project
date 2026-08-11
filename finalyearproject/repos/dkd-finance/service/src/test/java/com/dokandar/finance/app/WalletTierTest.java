package com.dokandar.finance.app;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.dokandar.finance.store.WalletStore;
import java.util.Optional;
import org.junit.jupiter.api.Test;

/**
 * F-1 regression guard. The wallet KYC tier must TRACK the Identity KYC lifecycle (was hardcoded V1),
 * so BR-035 per-tier caps bind. Guards the Identity-name -> V0..V3 mapping and the non-downgrading
 * re-tier from a KYC event. If a refactor re-freezes the tier or breaks the mapping, these fail.
 */
class WalletTierTest {

    private static final String DID = "did:dokandar:018f0000-0000-7000-8000-000000000001";

    @Test
    void mapKycTier_identityNamesToPolicyCodes() {
        assertEquals("V0", WalletService.mapKycTier("UNVERIFIED"));
        assertEquals("V1", WalletService.mapKycTier("BASIC"));
        assertEquals("V2", WalletService.mapKycTier("FULL"));
        assertEquals("V3", WalletService.mapKycTier("BUSINESS"));
        assertEquals("V2", WalletService.mapKycTier("V2"));      // defensive passthrough
        assertEquals("V1", WalletService.mapKycTier(" basic ")); // trim + case-insensitive
        assertNull(WalletService.mapKycTier("GOLD"));            // unknown -> null (skip, don't guess)
        assertNull(WalletService.mapKycTier(null));
    }

    private WalletService serviceWith(WalletStore wallets) {
        return new WalletService(wallets, null, null, null);
    }

    private WalletStore.WalletRow rowAtTier(String tier) {
        return new WalletStore.WalletRow("WLT-1", DID, "ACTIVE", tier, null, null, 0L, 0L);
    }

    @Test
    void setTierByDid_kycApprovedUpgradesV0ToV1() {
        WalletStore wallets = mock(WalletStore.class);
        when(wallets.lockByDid(DID)).thenReturn(Optional.of(rowAtTier("V0")));
        serviceWith(wallets).setTierByDid(DID, "BASIC");
        verify(wallets).updateTierByDid(eq(DID), eq("V1"), anyLong());
    }

    @Test
    void setTierByDid_neverDowngrades() {
        WalletStore wallets = mock(WalletStore.class);
        when(wallets.lockByDid(DID)).thenReturn(Optional.of(rowAtTier("V2")));
        serviceWith(wallets).setTierByDid(DID, "BASIC"); // V1 < V2 => no-op
        verify(wallets, never()).updateTierByDid(org.mockito.ArgumentMatchers.anyString(),
            org.mockito.ArgumentMatchers.anyString(), anyLong());
    }
}
