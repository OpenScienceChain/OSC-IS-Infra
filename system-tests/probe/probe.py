import argparse
import json
import os
import time
import uuid

import pika


HOST = os.getenv("RABBITMQ_HOST", "rabbitmq")
PORT = int(os.getenv("RABBITMQ_PORT", "5672"))
USER = os.getenv("RABBITMQ_USER", "osc_test")
PASSWORD = os.getenv("RABBITMQ_PASS", "osc_test_password")
EXCHANGE = "artifact.exchange"


def connect(attempts: int = 30) -> pika.BlockingConnection:
    parameters = pika.ConnectionParameters(
        host=HOST,
        port=PORT,
        credentials=pika.PlainCredentials(USER, PASSWORD),
        heartbeat=30,
    )
    last_error = None
    for _ in range(attempts):
        try:
            return pika.BlockingConnection(parameters)
        except pika.exceptions.AMQPError as error:
            last_error = error
            time.sleep(1)
    raise RuntimeError(f"RabbitMQ did not become ready: {last_error}")


def artifact_command(artifact_id: str) -> dict:
    return {
        "contractVersion": "v2",
        "artifactId": artifact_id,
        "title": f"System test artifact {artifact_id}",
        "description": "Exercises the OSC-IS asynchronous submission path.",
        "manifest": [
            {
                "filename": "evidence.txt",
                "algorithm": "sha256",
                "hash": "a" * 64,
            }
        ],
        "footprint": "b" * 64,
        "organization": {
            "id": "system-test-org",
            "name": "System Test Organization",
            "ledgerGroupName": "OSC.SystemTest",
            "ledgerApiUserId": "osc.system-test.portal",
            "artifactSchemaName": "osc.system-test.artifact",
        },
    }


def publish(count: int) -> list[str]:
    connection = connect()
    channel = connection.channel()
    ids = []
    for _ in range(count):
        artifact_id = str(uuid.uuid4())
        ids.append(artifact_id)
        channel.basic_publish(
            exchange=EXCHANGE,
            routing_key="artifact.submit",
            body=json.dumps(artifact_command(artifact_id)),
            properties=pika.BasicProperties(
                delivery_mode=2,
                content_type="application/json",
                message_id=artifact_id,
            ),
        )
    connection.close()
    print(json.dumps(ids))
    return ids


def wait_for_results(count: int, expected_state: str, timeout: int) -> list[dict]:
    connection = connect()
    channel = connection.channel()
    deadline = time.monotonic() + timeout
    results = []
    while len(results) < count and time.monotonic() < deadline:
        method, _, body = channel.basic_get(
            queue="artifact.submitted.queue", auto_ack=False
        )
        if method is None:
            time.sleep(0.5)
            continue
        event = json.loads(body)
        channel.basic_ack(method.delivery_tag)
        if event.get("submissionState") != expected_state:
            raise AssertionError(
                f"Expected {expected_state}, received {event.get('submissionState')}: {event}"
            )
        results.append(event)
    connection.close()
    if len(results) != count:
        raise TimeoutError(f"Expected {count} result events, received {len(results)}")
    print(json.dumps(results))
    return results


def queue_depth(queue: str, expected: int) -> None:
    connection = connect()
    result = connection.channel().queue_declare(queue=queue, durable=True, passive=True)
    connection.close()
    actual = result.method.message_count
    if actual != expected:
        raise AssertionError(f"Expected {expected} messages in {queue}, found {actual}")
    print(json.dumps({"queue": queue, "messages": actual}))


def main() -> None:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    publish_parser = subparsers.add_parser("publish")
    publish_parser.add_argument("--count", type=int, default=1)

    wait_parser = subparsers.add_parser("wait")
    wait_parser.add_argument("--count", type=int, default=1)
    wait_parser.add_argument("--state", choices=["SUCCESS", "FAILED"], required=True)
    wait_parser.add_argument("--timeout", type=int, default=45)

    depth_parser = subparsers.add_parser("depth")
    depth_parser.add_argument("--queue", required=True)
    depth_parser.add_argument("--expected", type=int, required=True)

    args = parser.parse_args()
    if args.command == "publish":
        publish(args.count)
    elif args.command == "wait":
        wait_for_results(args.count, args.state, args.timeout)
    else:
        queue_depth(args.queue, args.expected)


if __name__ == "__main__":
    main()
