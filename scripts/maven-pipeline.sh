#!/usr/bin/env bash
# =============================================================================
# TASK 4 - Shell-script "pipeline" for the Maven app
#   build -> unit test -> functional test -> performance test -> sonar scan
#   -> docker build -> push to Nexus & JFrog
#   -> deploy to Kubernetes with kubectl (image from Nexus, image from JFrog)
#
# Usage:
#   cp scripts/config.env.example scripts/config.env   # fill it in
#   ./scripts/maven-pipeline.sh                  # run every stage
#   ./scripts/maven-pipeline.sh build unit       # run selected stages only
#
# Stages: build unit functional perf sonar docker push-nexus push-jfrog
#         deploy-nexus deploy-jfrog
# Needs : java 17, mvn, docker, kubectl, envsubst, curl, jq
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
APP_DIR="$ROOT_DIR/java-app"

CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/config.env}"
if [ -f "$CONFIG_FILE" ]; then
  set -a; . "$CONFIG_FILE"; set +a
else
  echo "WARN: $CONFIG_FILE not found - relying on environment variables" >&2
fi

APP_NAME="${APP_NAME:-demo-app}"
VERSION="${VERSION:-1.0.$(date +%Y%m%d%H%M%S)}"     # unique per run -> no "already exists" in repos
NS_NEXUS="${NS_NEXUS:-demo-nexus}"
NS_JFROG="${NS_JFROG:-demo-jfrog}"
PERF_PORT="${PERF_PORT:-18080}"

NEXUS_IMAGE="${NEXUS_DOCKER_HOST:-}/${APP_NAME}:${VERSION}"
JFROG_IMAGE="${JFROG_HOST:-}/${JFROG_DOCKER_REPO:-}/${APP_NAME}:${VERSION}"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
need() { for v in "$@"; do [ -n "${!v:-}" ] || { echo "ERROR: $v is not set" >&2; exit 1; }; done; }
tool() { command -v "$1" >/dev/null || { echo "ERROR: '$1' not installed" >&2; exit 1; }; }

# exported because ci/settings.xml reads them as ${env.NEXUS_USER} etc.
export NEXUS_USER="${NEXUS_USER:-}" NEXUS_PASSWORD="${NEXUS_PASSWORD:-}" \
       JFROG_USER="${JFROG_USER:-}" JFROG_PASSWORD="${JFROG_PASSWORD:-}"

# ----------------------------------------------------------------------------- stages
stage_build() {
  log "Maven build (version $VERSION)"
  tool mvn
  cd "$APP_DIR"
  # work on the pom with a unique version, restore it afterwards
  cp pom.xml pom.xml.orig
  trap 'mv -f "$APP_DIR/pom.xml.orig" "$APP_DIR/pom.xml" 2>/dev/null || true' RETURN
  mvn -B -ntp -q versions:set -DnewVersion="$VERSION" -DgenerateBackupPoms=false
  mvn -B -ntp clean package -DskipTests
  # keep the versioned pom beside the jar for the later deploy stages
  cp pom.xml target/pom.versioned.xml
}

stage_unit() {
  log "Unit tests"
  cd "$APP_DIR" && mvn -B -ntp test
}

stage_functional() {
  log "Functional tests (failsafe, real HTTP server)"
  cd "$APP_DIR" && mvn -B -ntp failsafe:integration-test failsafe:verify
}

stage_perf() {
  log "Performance test (JMeter in Docker)"
  tool docker; tool curl
  cd "$APP_DIR"
  [ -f target/demo-app.jar ] || { echo "ERROR: run the 'build' stage first" >&2; exit 1; }

  PORT="$PERF_PORT" java -jar target/demo-app.jar & local app_pid=$!
  trap 'kill '"$app_pid"' 2>/dev/null || true' RETURN

  for _ in $(seq 1 30); do curl -sf "http://localhost:${PERF_PORT}/health" >/dev/null && break; sleep 1; done

  rm -f perf/results.jtl
  docker run --rm --network host -v "$PWD/perf":/work justb4/jmeter:5.5 \
    -n -t /work/load-test.jmx -Jhost=localhost -Jport="$PERF_PORT" -Jthreads=10 -Jloops=50 -l /work/results.jtl

  local failed total
  failed="$(awk -F, 'NR>1 && $8=="false"{c++} END{print c+0}' perf/results.jtl)"
  total="$(awk 'END{print NR-1}' perf/results.jtl)"
  echo "JMeter: $total samples, $failed failed"
  [ "$failed" -eq 0 ] || { echo "ERROR: performance test had failures" >&2; exit 1; }
}

stage_sonar() {
  log "SonarQube scan (dynamic, project-scoped, 24h token)"
  need SONAR_HOST_URL SONAR_ADMIN_TOKEN SONAR_PROJECT_KEY
  "$SCRIPT_DIR/sonar-scan.sh" "$APP_DIR"
}

stage_docker() {
  log "Docker build $APP_NAME:$VERSION"
  tool docker
  [ -f "$APP_DIR/target/demo-app.jar" ] || { echo "ERROR: run the 'build' stage first" >&2; exit 1; }
  docker build -t "$APP_NAME:$VERSION" "$APP_DIR"
}

mvn_deploy() {   # $1 = server id (nexus|jfrog)   $2 = repo url
  cd "$APP_DIR"
  [ -f target/pom.versioned.xml ] || { echo "ERROR: run the 'build' stage first" >&2; exit 1; }
  # deploy the already-built jar using the versioned pom (no rebuild)
  mvn -B -ntp -s ci/settings.xml deploy:deploy-file \
      -Dfile=target/demo-app.jar -DpomFile=target/pom.versioned.xml \
      -DrepositoryId="$1" -Durl="$2"
}

stage_push_nexus() {
  log "Push to Nexus (jar + image)"
  need NEXUS_MAVEN_URL NEXUS_DOCKER_HOST NEXUS_USER NEXUS_PASSWORD
  mvn_deploy nexus "$NEXUS_MAVEN_URL"
  echo "$NEXUS_PASSWORD" | docker login "$NEXUS_DOCKER_HOST" -u "$NEXUS_USER" --password-stdin
  docker tag  "$APP_NAME:$VERSION" "$NEXUS_IMAGE"
  docker push "$NEXUS_IMAGE"
  docker logout "$NEXUS_DOCKER_HOST" >/dev/null
}

stage_push_jfrog() {
  log "Push to JFrog (jar + image)"
  need JFROG_MAVEN_URL JFROG_HOST JFROG_DOCKER_REPO JFROG_USER JFROG_PASSWORD
  mvn_deploy jfrog "$JFROG_MAVEN_URL"
  echo "$JFROG_PASSWORD" | docker login "$JFROG_HOST" -u "$JFROG_USER" --password-stdin
  docker tag  "$APP_NAME:$VERSION" "$JFROG_IMAGE"
  docker push "$JFROG_IMAGE"
  docker logout "$JFROG_HOST" >/dev/null
}

k8s_deploy() {   # $1 namespace  $2 image  $3 registry host  $4 user  $5 password  $6 pull-secret name
  local ns="$1" image="$2" registry="$3" user="$4" pass="$5" secret="$6"
  tool kubectl; tool envsubst

  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -

  # registry credentials so the cluster can pull from the private registry
  kubectl -n "$ns" create secret docker-registry "$secret" \
      --docker-server="$registry" --docker-username="$user" --docker-password="$pass" \
      --dry-run=client -o yaml | kubectl apply -f -

  APP_NAME="$APP_NAME" NAMESPACE="$ns" IMAGE="$image" PULL_SECRET="$secret" \
    envsubst '${APP_NAME} ${NAMESPACE} ${IMAGE} ${PULL_SECRET}' < "$SCRIPT_DIR/k8s/app.yaml.tpl" \
    | kubectl apply -f -

  kubectl -n "$ns" rollout status "deployment/$APP_NAME" --timeout=180s
  kubectl -n "$ns" get pods -l "app=$APP_NAME" -o wide
}

stage_deploy_nexus() {
  log "kubectl deploy - image pulled from Nexus -> namespace $NS_NEXUS"
  need NEXUS_DOCKER_HOST NEXUS_USER NEXUS_PASSWORD
  k8s_deploy "$NS_NEXUS" "$NEXUS_IMAGE" "$NEXUS_DOCKER_HOST" "$NEXUS_USER" "$NEXUS_PASSWORD" regcred-nexus
}

stage_deploy_jfrog() {
  log "kubectl deploy - image pulled from JFrog -> namespace $NS_JFROG"
  need JFROG_HOST JFROG_DOCKER_REPO JFROG_USER JFROG_PASSWORD
  k8s_deploy "$NS_JFROG" "$JFROG_IMAGE" "$JFROG_HOST" "$JFROG_USER" "$JFROG_PASSWORD" regcred-jfrog
}

# ----------------------------------------------------------------------------- main
ALL_STAGES=(build unit functional perf sonar docker push-nexus push-jfrog deploy-nexus deploy-jfrog)
STAGES=("$@"); [ ${#STAGES[@]} -gt 0 ] || STAGES=("${ALL_STAGES[@]}")

for s in "${STAGES[@]}"; do
  fn="stage_${s//-/_}"
  declare -F "$fn" >/dev/null || { echo "Unknown stage '$s'. Valid: ${ALL_STAGES[*]}" >&2; exit 1; }
done

echo "Version: $VERSION | stages: ${STAGES[*]}"
for s in "${STAGES[@]}"; do
  ( "stage_${s//-/_}" )          # subshell: each stage's cd/trap stays isolated
done

log "ALL DONE - $APP_NAME:$VERSION"
