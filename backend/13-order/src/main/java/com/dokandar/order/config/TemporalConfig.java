package com.dokandar.order.config;

import com.google.protobuf.Duration;
import io.grpc.ManagedChannelBuilder;
import io.grpc.Status;
import io.grpc.StatusRuntimeException;
import io.temporal.api.workflowservice.v1.DescribeNamespaceRequest;
import io.temporal.api.workflowservice.v1.RegisterNamespaceRequest;
import io.temporal.client.WorkflowClient;
import io.temporal.client.WorkflowClientOptions;
import io.temporal.serviceclient.WorkflowServiceStubs;
import io.temporal.serviceclient.WorkflowServiceStubsOptions;
import io.temporal.worker.WorkerFactory;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * Temporal connection beans, hand-wired (the temporal-spring-boot-starter targets
 * Spring Boot 2.7 and is unsupported under Spring Boot 4, so we use the core SDK).
 * The WorkerFactory is created but NOT started here — the worker registers + starts
 * it on ApplicationReadyEvent (after DB bootstrap), mirroring the gRPC server's
 * context-event lifecycle. {@code /ready} never gates on Temporal (spec §8).
 */
@Configuration
public class TemporalConfig {

    private static final Logger log = LoggerFactory.getLogger(TemporalConfig.class);

    @Bean(destroyMethod = "shutdown")
    public WorkflowServiceStubs workflowServiceStubs(OrderProperties props) {
        // Build the channel ourselves so we can overrideAuthority("temporal") — the Elastic APM
        // Java agent names the gRPC dependency by the channel authority, so this yields a friendly
        // "temporal" node in Dependencies + the service map instead of a raw IP:7233 (the :authority
        // header is cosmetic for plaintext gRPC; the Temporal frontend does not validate it).
        io.grpc.ManagedChannel ch = ManagedChannelBuilder.forTarget(props.temporal.target)
                .usePlaintext()
                .overrideAuthority("temporal")
                .build();
        WorkflowServiceStubs stubs = WorkflowServiceStubs.newServiceStubs(
                WorkflowServiceStubsOptions.newBuilder()
                        .setChannel(ch)   // plaintext; internal network, no TLS
                        .build());
        // Self-provision the namespace so a clean deploy needs NO manual `temporal operator
        // namespace create` step: Temporal (unlike Kafka topics) does not auto-create namespaces,
        // and the worker fails fast with NOT_FOUND on ApplicationReadyEvent if it's missing.
        // Idempotent (ALREADY_EXISTS is ignored); waits for the registry cache to make it visible.
        ensureNamespace(stubs, props.temporal.namespace);
        return stubs;
    }

    /** Register {@code namespace} if absent, then block until it is describable (cache refresh). */
    private static void ensureNamespace(WorkflowServiceStubs stubs, String namespace) {
        var svc = stubs.blockingStub();
        try {
            svc.registerNamespace(RegisterNamespaceRequest.newBuilder()
                    .setNamespace(namespace)
                    .setWorkflowExecutionRetentionPeriod(Duration.newBuilder().setSeconds(259_200L).build()) // 3 days
                    .build());
            log.info("Temporal namespace '{}' registered", namespace);
        } catch (StatusRuntimeException e) {
            if (e.getStatus().getCode() != Status.Code.ALREADY_EXISTS) {
                throw e;
            }
            log.info("Temporal namespace '{}' already exists", namespace);
        }
        // Registration is async on the Temporal side; the namespace registry cache can lag a few
        // seconds. Poll DescribeNamespace so the worker (ApplicationReadyEvent) never races NOT_FOUND.
        for (int i = 0; i < 30; i++) {
            try {
                svc.describeNamespace(DescribeNamespaceRequest.newBuilder().setNamespace(namespace).build());
                return;
            } catch (StatusRuntimeException e) {
                if (e.getStatus().getCode() != Status.Code.NOT_FOUND) {
                    throw e;
                }
                try {
                    Thread.sleep(1_000L);
                } catch (InterruptedException ie) {
                    Thread.currentThread().interrupt();
                    return;
                }
            }
        }
        log.warn("Temporal namespace '{}' not visible after wait; worker may retry", namespace);
    }

    @Bean
    public WorkflowClient workflowClient(WorkflowServiceStubs stubs, OrderProperties props) {
        return WorkflowClient.newInstance(stubs,
                WorkflowClientOptions.newBuilder()
                        .setNamespace(props.temporal.namespace)
                        .build());
    }

    @Bean
    public WorkerFactory workerFactory(WorkflowClient client) {
        return WorkerFactory.newInstance(client);   // started by the worker bean on ApplicationReadyEvent
    }
}
