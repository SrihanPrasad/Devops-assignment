// =============================================================================
// TASK 1 - Jenkins pipeline: Maven app
//   build -> unit test -> functional test -> performance test -> Sonar scan
//   -> docker build -> push to Nexus & JFrog -> Argo CD deploy (sequentially)
//
// Job type : Pipeline -> Pipeline script from SCM
// Script Path: jenkins/Jenkinsfile.java
//
// Jenkins credentials required:
//   nexus-creds   Username/password
//   jfrog-creds   Username/password
//   argocd-token  Secret text
//
// SonarQube server name: sonarqube
// =============================================================================

pipeline {
    agent any

    options {
        timestamps()
        timeout(time: 45, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '10'))
        disableConcurrentBuilds()
    }

    environment {
        APP_NAME          = 'demo-app'
        APP_DIR           = 'java-app'
        ARGO_APP          = 'java-app'
        VERSION           = "1.0.${BUILD_NUMBER}"

        // Nexus
        NEXUS_MAVEN_URL   = 'http://172.31.21.234:8081/repository/maven-releases/'
        NEXUS_DOCKER_HOST = '44.208.15.96:8082'

        // JFrog Cloud
        JFROG_HOST        = 'trialmzbpgd.jfrog.io'
        JFROG_MAVEN_URL   = 'https://trialmzbpgd.jfrog.io/artifactory/demo-maven-local'
        JFROG_DOCKER_REPO = 'demo-docker-local'

        // Argo CD
        ARGOCD_SERVER     = '172.17.0.1:8443'
    }

    stages {

        // ---------------------------------------------------------
        // 1. Checkout source code
        // ---------------------------------------------------------
        stage('Checkout') {
            steps {
                checkout scm
                sh 'java -version && mvn -version'
            }
        }

        // ---------------------------------------------------------
        // 2. Maven build
        // ---------------------------------------------------------
        stage('Maven Build') {
            steps {
                dir(APP_DIR) {
                    sh "mvn -B -q versions:set -DnewVersion=${VERSION} -DgenerateBackupPoms=false"
                    sh 'mvn -B clean package -DskipTests'
                }
            }
        }

        // ---------------------------------------------------------
        // 3. Unit tests
        // ---------------------------------------------------------
        stage('Unit Tests') {
            steps {
                dir(APP_DIR) {
                    sh 'mvn -B test'
                }
            }
            post {
                always {
                    junit allowEmptyResults: true,
                          testResults: "${APP_DIR}/target/surefire-reports/*.xml"
                }
            }
        }

        // ---------------------------------------------------------
        // 4. Functional tests
        // ---------------------------------------------------------
        stage('Functional Tests') {
            steps {
                dir(APP_DIR) {
                    sh 'mvn -B failsafe:integration-test failsafe:verify'
                }
            }
            post {
                always {
                    junit allowEmptyResults: true,
                          testResults: "${APP_DIR}/target/failsafe-reports/*.xml"
                }
            }
        }

        // ---------------------------------------------------------
        // 5. Performance tests
        // ---------------------------------------------------------
        stage('Performance Tests') {
            steps {
                dir(APP_DIR) {
                    sh '''
                        set -e

                        PORT=18080 java -jar target/demo-app.jar &
                        APP_PID=$!
                        trap "kill $APP_PID 2>/dev/null || true" EXIT

                        for i in $(seq 1 30); do
                            curl -sf http://localhost:18080/health >/dev/null && break
                            sleep 1
                        done

                        rm -f perf/results.jtl

                        docker run --rm --network container:jenkins \
                            -v /var/lib/docker/volumes/jenkins_home/_data/workspace/maven-pipeline/java-app/perf:/work \
                            justb4/jmeter:5.5 \
                            -n -t /work/load-test.jmx \
                            -Jhost=localhost \
                            -Jport=18080 \
                            -Jthreads=10 \
                            -Jloops=50 \
                            -l /work/results.jtl

                        FAILED=$(awk -F, 'NR>1 && $8=="false"{c++} END{print c+0}' perf/results.jtl)
                        TOTAL=$(awk 'END{print NR-1}' perf/results.jtl)

                        echo "JMeter: $TOTAL samples, $FAILED failed"
                        [ "$FAILED" -eq 0 ]
                    '''
                }
            }
            post {
                always {
                    archiveArtifacts artifacts: "${APP_DIR}/perf/results.jtl",
                                     allowEmptyArchive: true
                }
            }
        }

        // ---------------------------------------------------------
        // 6. SonarQube scan
        // ---------------------------------------------------------
        stage('SonarQube Scan') {
            steps {
                dir(APP_DIR) {
                    withSonarQubeEnv('sonarqube') {
                        sh '''
                            mvn -B org.sonarsource.scanner.maven:sonar-maven-plugin:5.7.0.6970:sonar \
                                -Dsonar.projectKey=demo-app \
                                -Dsonar.projectName=demo-app
                        '''
                    }
                }
            }
        }

        // ---------------------------------------------------------
        // 7. Quality gate
        // ---------------------------------------------------------
        stage('Quality Gate') {
            steps {
                timeout(time: 10, unit: 'MINUTES') {
                    waitForQualityGate abortPipeline: true
                }
            }
        }

        // ---------------------------------------------------------
        // 8. Docker build
        // ---------------------------------------------------------
        stage('Docker Build') {
            steps {
                dir(APP_DIR) {
                    sh "docker build -t ${APP_NAME}:${VERSION} ."
                }
            }
        }

        // ---------------------------------------------------------
        // 9. Publish artifacts to Nexus and JFrog
        // ---------------------------------------------------------
        stage('Publish Artifacts') {
            parallel {

                stage('Push to Nexus') {
                    steps {
                        withCredentials([
                            usernamePassword(
                                credentialsId: 'nexus-creds',
                                usernameVariable: 'NEXUS_USER',
                                passwordVariable: 'NEXUS_PASSWORD'
                            )
                        ]) {
                            dir(APP_DIR) {
                                sh "mvn -B -s ci/settings.xml deploy -DskipTests " +
                                   "-DaltDeploymentRepository=nexus::default::${NEXUS_MAVEN_URL}"
                            }

                            sh '''
                                set -e

                                echo "$NEXUS_PASSWORD" | docker login "$NEXUS_DOCKER_HOST" \
                                    -u "$NEXUS_USER" --password-stdin

                                docker tag "$APP_NAME:$VERSION" \
                                    "$NEXUS_DOCKER_HOST/$APP_NAME:$VERSION"

                                docker push "$NEXUS_DOCKER_HOST/$APP_NAME:$VERSION"

                                docker logout "$NEXUS_DOCKER_HOST"
                            '''
                        }
                    }
                }

                stage('Push to JFrog') {
                    steps {
                        withCredentials([
                            usernamePassword(
                                credentialsId: 'jfrog-creds',
                                usernameVariable: 'JFROG_USER',
                                passwordVariable: 'JFROG_PASSWORD'
                            )
                        ]) {
                            dir(APP_DIR) {
                                sh "mvn -B -s ci/settings.xml deploy -DskipTests " +
                                   "-DaltDeploymentRepository=jfrog::default::${JFROG_MAVEN_URL}"
                            }

                            sh '''
                                set -e

                                echo "$JFROG_PASSWORD" | docker login "$JFROG_HOST" \
                                    -u "$JFROG_USER" --password-stdin

                                docker tag "$APP_NAME:$VERSION" \
                                    "$JFROG_HOST/$JFROG_DOCKER_REPO/$APP_NAME:$VERSION"

                                docker push \
                                    "$JFROG_HOST/$JFROG_DOCKER_REPO/$APP_NAME:$VERSION"

                                docker logout "$JFROG_HOST"
                            '''
                        }
                    }
                }
            }
        }

        // ---------------------------------------------------------
        // 10. Deploy using Argo CD - SEQUENTIAL, NOT PARALLEL
        // ---------------------------------------------------------
        stage('Deploy via Argo CD') {
            steps {
                withCredentials([
                    string(
                        credentialsId: 'argocd-token',
                        variable: 'ARGOCD_AUTH_TOKEN'
                    )
                ]) {
                    sh '''
                        set -e

                        export ARGOCD_SERVER
                        export ARGOCD_AUTH_TOKEN

                        # =================================================
                        # Deploy Nexus image first
                        # =================================================
                        APP=${ARGO_APP}-nexus
                        IMAGE=$NEXUS_DOCKER_HOST/$APP_NAME:$VERSION

                        echo "========================================"
                        echo "Deploying Nexus image: $IMAGE"
                        echo "Argo CD application: $APP"
                        echo "========================================"

                        argocd app set "$APP" \
                            --grpc-web \
                            --insecure \
                            --kustomize-image "${ARGO_APP}=$IMAGE"

                        argocd app sync "$APP" \
                            --grpc-web \
                            --insecure

                        argocd app wait "$APP" \
                            --grpc-web \
                            --insecure \
                            --health \
                            --timeout 180

                        argocd app get "$APP" \
                            --grpc-web \
                            --insecure

                        echo "Nexus application deployment completed."

                        # =================================================
                        # Deploy JFrog image after Nexus completes
                        # =================================================
                        APP=${ARGO_APP}-jfrog
                        IMAGE=$JFROG_HOST/$JFROG_DOCKER_REPO/$APP_NAME:$VERSION

                        echo "========================================"
                        echo "Deploying JFrog image: $IMAGE"
                        echo "Argo CD application: $APP"
                        echo "========================================"

                        argocd app set "$APP" \
                            --grpc-web \
                            --insecure \
                            --kustomize-image "${ARGO_APP}=$IMAGE"

                        argocd app sync "$APP" \
                            --grpc-web \
                            --insecure

                        argocd app wait "$APP" \
                            --grpc-web \
                            --insecure \
                            --health \
                            --timeout 180

                        argocd app get "$APP" \
                            --grpc-web \
                            --insecure

                        echo "JFrog application deployment completed."
                        echo "Both Argo CD applications deployed successfully."
                    '''
                }
            }
        }
    }

    // ---------------------------------------------------------
    // Post-build actions
    // ---------------------------------------------------------
    post {
        success {
            echo "Pipeline OK - ${APP_NAME}:${VERSION} deployed from Nexus and from JFrog"
        }
        failure {
            echo 'Pipeline FAILED - check the failing stage log above'
        }
        always {
            echo 'Keeping workspace for debugging'
        }
    }
}
