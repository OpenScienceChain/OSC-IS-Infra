#!/usr/bin/env python3
"""Check a saved, narrowly targeted Terraform plan for the public demo edge."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

DIST = "aws_cloudfront_distribution.edge"
FUNCTION = "aws_cloudfront_function.spa_rewrite"
VPC_ORIGIN = "aws_cloudfront_vpc_origin.external_demo_api[0]"
WAF = "aws_wafv2_web_acl.edge"
API_ORIGIN = "private-demo-api-usrse260930"
API_ALB_ARN = (
    "arn:aws:elasticloadbalancing:us-west-2:269624229733:"
    "loadbalancer/app/k8s-oscapps-oscdemoa-5938afeb16/f59ddecd5a4a24ef"
)

ALLOWED = {
    "harden": {DIST: ["update"], FUNCTION: ["create"], WAF: ["update"]},
    "origin": {VPC_ORIGIN: ["create"]},
    "attach": {DIST: ["update"]},
    "detach": {DIST: ["update"]},
    "remove-origin": {VPC_ORIGIN: ["delete"]},
}


def fail(message: str) -> None:
    raise SystemExit(f"Unsafe demo edge plan: {message}")


def origin_ids(value: dict) -> set[str]:
    return {origin.get("origin_id") for origin in value.get("origin", [])}


def one_block(value: dict, name: str) -> dict:
    blocks = value.get(name) or []
    if len(blocks) != 1 or not isinstance(blocks[0], dict):
        fail(f"expected one {name} block")
    return blocks[0]


def check_distribution(value: dict, *, attached: bool) -> None:
    if value.get("id") != "E26XTII1H57RTX":
        fail("distribution identity changed")
    if value.get("aliases") != ["demo.osc-staging.org"]:
        fail("public alias changed")
    expected_origins = {"static-edge", API_ORIGIN} if attached else {"static-edge"}
    if origin_ids(value) != expected_origins:
        fail("unexpected distribution origin set")
    static_origin = [origin for origin in value["origin"] if origin.get("origin_id") == "static-edge"][0]
    if not static_origin.get("origin_access_control_id") or static_origin.get("custom_origin_config"):
        fail("static origin must retain S3 origin access control")
    if value.get("custom_error_response"):
        fail("distribution-wide error rewriting is forbidden")
    default = one_block(value, "default_cache_behavior")
    if default.get("target_origin_id") != "static-edge":
        fail("default behavior must stay on the static origin")
    if default.get("viewer_protocol_policy") != "redirect-to-https":
        fail("default behavior must redirect to HTTPS")
    functions = default.get("function_association") or []
    if len(functions) != 1 or functions[0].get("event_type") != "viewer-request":
        fail("static SPA rewrite function missing")
    if default.get("lambda_function_association"):
        fail("unexpected Lambda@Edge association")
    ordered = value.get("ordered_cache_behavior") or []
    if attached:
        if len(ordered) != 1:
            fail("expected exactly one ordered API behavior")
        api = ordered[0]
        if api.get("path_pattern") != "/api/*" or api.get("target_origin_id") != API_ORIGIN:
            fail("API path or target changed")
        if api.get("viewer_protocol_policy") != "https-only":
            fail("API viewer protocol must be HTTPS only")
        if set(api.get("allowed_methods") or []) != {
            "GET", "HEAD", "OPTIONS", "PUT", "PATCH", "POST", "DELETE"
        }:
            fail("API methods differ from the reviewed set")
        if set(api.get("cached_methods") or []) != {"GET", "HEAD"}:
            fail("API cached methods changed")
        if api.get("cache_policy_id") != "a206f89f-c17e-4bde-942a-450290111560":
            fail("API must use the zero-TTL cache policy")
        if api.get("origin_request_policy_id") != "07026742-00b4-4965-934e-d89eb9d7893a":
            fail("API must forward viewer cookies and headers")
        if api.get("response_headers_policy_id") != default.get("response_headers_policy_id"):
            fail("API must use the static security response headers policy")
        if api.get("function_association") or api.get("lambda_function_association"):
            fail("API behavior must not run edge functions")
        private_origin = [origin for origin in value["origin"] if origin.get("origin_id") == API_ORIGIN][0]
        if len(private_origin.get("vpc_origin_config") or []) != 1:
            fail("API origin must be a CloudFront VPC origin")
    elif ordered:
        fail("static distribution must not have an API behavior")


def check_unchanged_distribution(before: dict, after: dict) -> None:
    for field in (
        "default_cache_behavior", "viewer_certificate", "web_acl_id", "restrictions",
        "is_ipv6_enabled", "http_version", "enabled", "aliases", "default_root_object",
        "logging_config", "custom_error_response", "origin_group",
    ):
        if before.get(field) != after.get(field):
            fail(f"distribution {field} changed during API attach/detach")
    previous_static = [origin for origin in before["origin"] if origin.get("origin_id") == "static-edge"]
    next_static = [origin for origin in after["origin"] if origin.get("origin_id") == "static-edge"]
    if previous_static != next_static:
        fail("static origin changed during API attach/detach")


def check_rate_rule(rule: dict, *, aggregate: str, limit: int, window: int) -> None:
    action = one_block(rule, "action")
    block = one_block(action, "block")
    response = one_block(block, "custom_response")
    if response.get("response_code") != 429:
        fail(f"{rule.get('name')} must block with 429")
    statement = one_block(rule, "statement")
    rate = one_block(statement, "rate_based_statement")
    if (rate.get("aggregate_key_type"), rate.get("limit"), rate.get("evaluation_window_sec")) != (
        aggregate, limit, window
    ):
        fail(f"{rule.get('name')} rate enforcement changed")
    if not rate.get("scope_down_statement"):
        fail(f"{rule.get('name')} lost route scope")


def check_waf(value: dict) -> None:
    rules = {rule.get("name"): rule for rule in value.get("rule", [])}
    for name, priority in {
        "RejectAmbiguousApiPaths": 21,
        "BlockPrivateApiPaths": 22,
        "BlockUnlistedApiPaths": 23,
    }.items():
        if rules.get(name, {}).get("priority") != priority:
            fail(f"{name} is missing or has the wrong priority")
    ambiguous = one_block(rules["RejectAmbiguousApiPaths"], "statement")
    if ambiguous.get("and_statement") or len(ambiguous.get("or_statement") or []) != 1:
        fail("ambiguous path rejection must not require an API prefix")
    if len(one_block(ambiguous, "or_statement").get("statement") or []) != 3:
        fail("ambiguous path rejection must cover encoding, slash and dot variants")
    check_rate_rule(rules.get("DemoHistoryRateLimit") or {}, aggregate="IP", limit=300, window=60)
    check_rate_rule(rules.get("DemoAccountEntryRateLimit") or {}, aggregate="IP", limit=100, window=300)
    check_rate_rule(rules.get("DemoAccountGlobalRateLimit") or {}, aggregate="CONSTANT", limit=600, window=300)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=ALLOWED)
    parser.add_argument("plan_json", type=Path)
    args = parser.parse_args()
    plan = json.loads(args.plan_json.read_text(encoding="utf-8"))
    changes = {
        item["address"]: item
        for item in plan.get("resource_changes", [])
        if item.get("change", {}).get("actions") not in (["no-op"], ["read"])
    }
    actual = {key: item["change"]["actions"] for key, item in changes.items()}
    if actual != ALLOWED[args.mode]:
        fail(f"unexpected actions {actual!r}, expected {ALLOWED[args.mode]!r}")

    if args.mode in {"harden", "attach", "detach"}:
        change = changes[DIST]["change"]
        before = change["before"]
        after = change["after"]
        if before.get("id") != after.get("id"):
            fail("distribution replacement is forbidden")
        if args.mode == "harden":
            if origin_ids(before) != {"static-edge"} or before.get("ordered_cache_behavior"):
                fail("hardening must start from the static edge")
            check_distribution(after, attached=False)
            check_waf(changes[WAF]["change"]["after"])
            function = changes[FUNCTION]["change"]["after"]
            if function.get("name") != "osc-usrse26-usrse26r1-spa-rewrite":
                fail("unexpected rewrite function")
        elif args.mode == "attach":
            check_distribution(before, attached=False)
            check_distribution(after, attached=True)
            check_unchanged_distribution(before, after)
        else:
            check_distribution(before, attached=True)
            check_distribution(after, attached=False)
            check_unchanged_distribution(before, after)
    if args.mode == "origin":
        endpoint = one_block(changes[VPC_ORIGIN]["change"]["after"], "vpc_origin_endpoint_config")
        if endpoint.get("arn") != API_ALB_ARN or endpoint.get("origin_protocol_policy") != "http-only":
            fail("VPC origin does not target the reviewed private ALB on HTTP")
        if endpoint.get("name") != "osc-usrse26-usrse26r1-usrse260930-api":
            fail("VPC origin name changed")
    print(f"Checked {args.mode} edge plan: {len(changes)} expected changes only.")


if __name__ == "__main__":
    main()
