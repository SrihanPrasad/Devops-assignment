from flask import Flask, jsonify, request

from .calculator import add


def create_app() -> Flask:
    app = Flask(__name__)

    @app.get("/")
    def index():
        return "Hello from demo-py-app"

    @app.get("/health")
    def health():
        return "OK"

    @app.get("/add")
    def add_endpoint():
        try:
            a = int(request.args["a"])
            b = int(request.args["b"])
        except (KeyError, ValueError):
            return jsonify(error="a and b must be integers"), 400
        return str(add(a, b))

    return app
