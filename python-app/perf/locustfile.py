"""Performance test. Run headless:

    locust -f perf/locustfile.py --headless -u 10 -r 5 -t 30s \
           --host http://localhost:8000 --csv perf/results --exit-code-on-error 1
"""
from locust import HttpUser, between, task


class DemoUser(HttpUser):
    wait_time = between(0.1, 0.5)

    @task(3)
    def health(self):
        self.client.get("/health")

    @task(1)
    def add(self):
        with self.client.get("/add?a=20&b=22", catch_response=True) as r:
            if r.text != "42":
                r.failure(f"expected 42 got {r.text}")
