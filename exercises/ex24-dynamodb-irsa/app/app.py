import os
import boto3
from flask import Flask, request, jsonify

app = Flask(__name__)

TABLE_NAME = os.environ.get("DYNAMODB_TABLE", "Customers")
REGION     = os.environ.get("AWS_REGION", "us-east-1")

# boto3 picks up credentials automatically from IRSA — no keys needed
dynamodb = boto3.resource("dynamodb", region_name=REGION)
table    = dynamodb.Table(TABLE_NAME)


# ── Write Customer ────────────────────────────────────────
@app.route("/customers", methods=["POST"])
def write_customer():
    data = request.get_json()
    if not data.get("customerId"):
        return jsonify({"error": "customerId is required"}), 400

    table.put_item(Item=data)
    return jsonify({"message": "Customer created", "customerId": data["customerId"]}), 201


# ── Read Customer ─────────────────────────────────────────
@app.route("/customers/<customer_id>", methods=["GET"])
def read_customer(customer_id):
    response = table.get_item(Key={"customerId": customer_id})
    item = response.get("Item")
    if not item:
        return jsonify({"error": "Customer not found"}), 404

    return jsonify(item), 200


# ── Update Customer ───────────────────────────────────────
@app.route("/customers/<customer_id>", methods=["PATCH"])
def update_customer(customer_id):
    data = request.get_json()
    if not data:
        return jsonify({"error": "No fields to update"}), 400

    # Build update expression dynamically from request body
    update_expr   = "SET " + ", ".join(f"#{k} = :{k}" for k in data)
    expr_names    = {f"#{k}": k for k in data}
    expr_values   = {f":{k}": v for k, v in data.items()}

    response = table.update_item(
        Key={"customerId": customer_id},
        UpdateExpression=update_expr,
        ExpressionAttributeNames=expr_names,
        ExpressionAttributeValues=expr_values,
        ReturnValues="ALL_NEW",
    )
    return jsonify(response["Attributes"]), 200


# ── Health check ──────────────────────────────────────────
@app.route("/health", methods=["GET"])
def health():
    return jsonify({"status": "ok"}), 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)