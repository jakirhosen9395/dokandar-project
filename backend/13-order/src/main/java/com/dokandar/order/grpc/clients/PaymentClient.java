package com.dokandar.order.grpc.clients;

import com.dokandar.order.config.OrderProperties;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.MediaType;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientException;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Payment-intent client. 09-payment exposes NO gRPC, so the saga creates the intent
 * over internal REST: POST {paymentRestUrl}/api/v1/payment/intents, authed with the
 * shared {@code x-internal-token}. FAIL-CLOSED: a non-2xx or transport error throws
 * {@link PaymentException} and the saga compensates.
 */
@Component
public class PaymentClient {

    private static final Logger log = LoggerFactory.getLogger(PaymentClient.class);

    private final RestClient restClient;
    private final String baseUrl;
    private final String internalToken;

    public PaymentClient(OrderProperties props) {
        this.baseUrl = props.peer.paymentRestUrl;
        this.internalToken = props.internal.serviceToken;
        this.restClient = RestClient.create();
    }

    /**
     * Create a COD payment intent for one sub-order's amount. Returns the intent id +
     * state from the payment service; throws {@link PaymentException} on non-2xx /
     * transport error.
     */
    public PaymentIntent createIntent(String orderId, String customerId, String shopkeeperId,
                                      long amountMinor, String currency) {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("order_id", orderId);
        body.put("customer_id", customerId);
        body.put("shopkeeper_id", shopkeeperId);
        body.put("provider", "cod");
        body.put("amount_minor", amountMinor);
        body.put("currency", currency == null || currency.isBlank() ? "BDT" : currency);

        try {
            @SuppressWarnings("unchecked")
            Map<String, Object> resp = restClient.post()
                    .uri(baseUrl + "/api/v1/payment/intents")
                    .header("x-internal-token", internalToken == null ? "" : internalToken)
                    .contentType(MediaType.APPLICATION_JSON)
                    .body(body)
                    .retrieve()
                    .body(Map.class);

            if (resp == null) {
                throw new PaymentException("payment_empty_response", "payment intent response was empty", null);
            }
            String id = str(resp, "id", "intent_id");
            String state = str(resp, "state", "status");
            return new PaymentIntent(id, state);
        } catch (PaymentException e) {
            throw e;
        } catch (RestClientException e) {  // covers non-2xx (HttpClient/ServerErrorException) + transport
            log.warn("createIntent failed order={} amount={}", orderId, amountMinor, e);
            throw new PaymentException("payment_unavailable", "payment intent create failed", e);
        }
    }

    private static String str(Map<String, Object> m, String primary, String fallback) {
        Object v = m.getOrDefault(primary, m.get(fallback));
        return v == null ? null : v.toString();
    }

    /** The created intent: id + state (e.g. pending for COD). */
    public record PaymentIntent(String id, String state) {}

    /** Thrown on a non-2xx or transport failure creating the intent (fail-closed). */
    public static class PaymentException extends RuntimeException {
        private final String code;
        public PaymentException(String code, String message, Throwable cause) {
            super(message, cause);
            this.code = code;
        }
        public String getCode() { return code; }
    }
}
