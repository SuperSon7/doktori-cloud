FROM eclipse-temurin:21-jdk AS builder

WORKDIR /workspace
COPY 5-team-service-be/ /workspace/5-team-service-be/

WORKDIR /workspace/5-team-service-be
RUN chmod +x ./gradlew && ./gradlew :chat:bootJar --no-daemon

FROM eclipse-temurin:21-jre

WORKDIR /app
COPY --from=builder /workspace/5-team-service-be/chat/build/libs/doktori-chat.jar /app/doktori-chat.jar

EXPOSE 8081
ENTRYPOINT ["java", "-jar", "/app/doktori-chat.jar"]

