# The jar is built by Maven *before* docker build (pipeline stage order),
# so the image only needs a JRE. Keeps the image small and the build fast.
FROM eclipse-temurin:17-jre-alpine

RUN addgroup -S app && adduser -S app -G app
WORKDIR /app
COPY target/demo-app.jar /app/demo-app.jar

USER app
ENV PORT=8080
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s CMD wget -qO- http://localhost:8080/health || exit 1
ENTRYPOINT ["java", "-jar", "/app/demo-app.jar"]
