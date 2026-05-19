FROM eclipse-temurin:21-jdk AS builder

WORKDIR /workspace
COPY 5-team-service-be/ /workspace/5-team-service-be/

WORKDIR /workspace/5-team-service-be
RUN chmod +x ./gradlew && ./gradlew :api:bootJar --no-daemon

FROM eclipse-temurin:21-jre

WORKDIR /app
COPY --from=builder /workspace/5-team-service-be/api/build/libs/doktori-api.jar /app/doktori-api.jar

EXPOSE 8080
ENTRYPOINT ["java", "-jar", "/app/doktori-api.jar"]

