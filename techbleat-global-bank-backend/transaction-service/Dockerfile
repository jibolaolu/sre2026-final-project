FROM maven:3.9-eclipse-temurin-17 AS build
WORKDIR /app
COPY pom.xml .
COPY src ./src
RUN mvn clean package -DskipTests

# Use the noble (Ubuntu 24.04) variant — it ships with the latest upstream
# security patches and significantly reduces fixable HIGH/CRITICAL CVEs vs jammy.
FROM eclipse-temurin:17-jre-noble
WORKDIR /app
RUN useradd -m -u 1001 app && chown app:app /app

# Upgrade OS packages for security patches, then fetch the OTel Java agent.
# When JAVA_TOOL_OPTIONS is unset (the default) the agent is present on disk
# but not activated — the service runs normally without a collector.
RUN apt-get update && apt-get upgrade -y --no-install-recommends \
    && apt-get install -y --no-install-recommends wget \
    && wget -q -O /app/opentelemetry-javaagent.jar \
       https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v2.9.0/opentelemetry-javaagent.jar \
    && apt-get remove -y wget && apt-get autoremove -y && rm -rf /var/lib/apt/lists/*

COPY --from=build /app/target/transaction-service-1.0.0.jar app.jar
RUN chown app:app /app/app.jar /app/opentelemetry-javaagent.jar
USER app
ENTRYPOINT ["java", "-jar", "app.jar"]
