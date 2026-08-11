import com.google.protobuf.gradle.id

plugins {
    kotlin("jvm") version "2.4.0"
    kotlin("plugin.serialization") version "2.4.0"
    id("com.google.protobuf") version "0.9.5"
    id("com.gradleup.shadow") version "9.0.0-beta11"
    application
}

group = "com.dokandar"
version = "0.1.0"

repositories { mavenCentral() }

val ktor = "3.5.0"
val grpcV = "1.68.1"
val protobufV = "4.28.3"
val grpcKt = "1.4.1"

dependencies {
    // Ktor server
    implementation("io.ktor:ktor-server-netty:$ktor")
    implementation("io.ktor:ktor-server-content-negotiation:$ktor")
    implementation("io.ktor:ktor-serialization-kotlinx-json:$ktor")
    implementation("io.ktor:ktor-server-call-id:$ktor")
    implementation("io.ktor:ktor-server-status-pages:$ktor")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.9.0")
    // DB
    implementation("com.zaxxer:HikariCP:6.2.1")
    implementation("org.postgresql:postgresql:42.7.4")
    // Kafka
    implementation("org.apache.kafka:kafka-clients:3.8.1")
    // gRPC
    implementation("io.grpc:grpc-netty-shaded:$grpcV")
    implementation("io.grpc:grpc-protobuf:$grpcV")
    implementation("io.grpc:grpc-stub:$grpcV")
    implementation("io.grpc:grpc-kotlin-stub:$grpcKt")
    implementation("com.google.protobuf:protobuf-kotlin:$protobufV")
    implementation("javax.annotation:javax.annotation-api:1.3.2")
    // JWT verify
    implementation("com.auth0:java-jwt:4.4.0")
    // Mongo log sink
    implementation("org.mongodb:mongodb-driver-sync:5.2.1")
    // Prometheus
    implementation("io.prometheus:simpleclient:0.16.0")
    implementation("io.prometheus:simpleclient_common:0.16.0")
    // Elastic APM API (read trace ids as fallback; primary is MDC)
    implementation("co.elastic.apm:apm-agent-api:1.55.6")
    // logging
    implementation("ch.qos.logback:logback-classic:1.5.12")
}

protobuf {
    protoc { artifact = "com.google.protobuf:protoc:$protobufV" }
    plugins {
        id("grpc") { artifact = "io.grpc:protoc-gen-grpc-java:$grpcV" }
        id("grpckt") { artifact = "io.grpc:protoc-gen-grpc-kotlin:$grpcKt:jdk8@jar" }
    }
    generateProtoTasks {
        all().forEach {
            it.plugins { id("grpc"); id("grpckt") }
            it.builtins { id("kotlin") }
        }
    }
}

kotlin { jvmToolchain(21) }

application { mainClass.set("com.dokandar.review.ApplicationKt") }

tasks.shadowJar {
    archiveBaseName.set("review")
    archiveClassifier.set("")
    archiveVersion.set("")
    mergeServiceFiles()
}
