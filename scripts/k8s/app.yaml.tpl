# Rendered with envsubst by scripts/maven-pipeline.sh
#   ${APP_NAME} ${NAMESPACE} ${IMAGE} ${PULL_SECRET}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP_NAME}
  namespace: ${NAMESPACE}
spec:
  replicas: 2
  selector:
    matchLabels:
      app: ${APP_NAME}
  template:
    metadata:
      labels:
        app: ${APP_NAME}
    spec:
      imagePullSecrets:
        - name: ${PULL_SECRET}
      containers:
        - name: ${APP_NAME}
          image: ${IMAGE}
          ports:
            - containerPort: 8080
          readinessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 15
            periodSeconds: 20
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 512Mi
---
apiVersion: v1
kind: Service
metadata:
  name: ${APP_NAME}
  namespace: ${NAMESPACE}
spec:
  type: ClusterIP
  selector:
    app: ${APP_NAME}
  ports:
    - port: 80
      targetPort: 8080
