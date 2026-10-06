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

ALLOWED = {
    "harden": {DIST: ["update"], FUNCTION: ["create"], WAF: ["update"]},
    "origin": {VPC_ORIGIN: ["create"]},
    "attach": {DIST: ["update"]},
    "detach": {DIST: ["update"]},
    "manifest-body": {WAF: ["update"]},
    "reject-encoding": {WAF: ["update"]},
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


def check_distribution(
    value: dict, *, attached: bool, distribution_id: str, api_origin: str,
    api_cache_policy_id: str, api_origin_request_policy_id: str,
) -> None:
    if value.get("id") != distribution_id:
        fail("distribution identity changed")
    if value.get("aliases") != ["demo.osc-staging.org"]:
        fail("public alias changed")
    expected_origins = {"static-edge", api_origin} if attached else {"static-edge"}
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
        if api.get("path_pattern") != "/api/*" or api.get("target_origin_id") != api_origin:
            fail("API path or target changed")
        if api.get("viewer_protocol_policy") != "https-only":
            fail("API viewer protocol must be HTTPS only")
        if set(api.get("allowed_methods") or []) != {
            "GET", "HEAD", "OPTIONS", "PUT", "PATCH", "POST", "DELETE"
        }:
            fail("API methods differ from the reviewed set")
        if set(api.get("cached_methods") or []) != {"GET", "HEAD"}:
            fail("API cached methods changed")
        if api.get("cache_policy_id") != api_cache_policy_id:
            fail("API must use the zero-TTL cache policy")
        if api.get("origin_request_policy_id") != api_origin_request_policy_id:
            fail("API must forward viewer cookies and headers")
        if api.get("response_headers_policy_id") != default.get("response_headers_policy_id"):
            fail("API must use the static security response headers policy")
        if api.get("function_association") or api.get("lambda_function_association"):
            fail("API behavior must not run edge functions")
        private_origin = [origin for origin in value["origin"] if origin.get("origin_id") == api_origin][0]
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


def normalize_provider_empty_fields(value):
    if isinstance(value, list):
        return [normalize_provider_empty_fields(item) for item in value]
    if isinstance(value, dict):
        return {
            key: normalize_provider_empty_fields(item)
            for key, item in value.items()
            if key not in {"custom_response_body_key", "version"} or item not in (None, "")
        }
    return value


def check_reject_encoding_waf(before: dict, after: dict) -> None:
    check_waf(before)
    check_waf(after)
    old_rules = {rule["name"]: rule for rule in before.get("rule", [])}
    new_rules = {rule["name"]: rule for rule in after.get("rule", [])}
    if set(new_rules) != set(old_rules) | {"RejectEncodedApiBodies"}:
        fail("encoding rejection must add only one WAF rule")
    for name in old_rules:
        if normalize_provider_empty_fields(old_rules[name]) != normalize_provider_empty_fields(new_rules[name]):
            fail(f"existing WAF rule {name} changed")
    for key in set(before) | set(after):
        if key != "rule" and before.get(key) != after.get(key):
            fail(f"existing WAF field {key} changed")

    rule = new_rules["RejectEncodedApiBodies"]
    if rule.get("priority") != 8 or one_block(one_block(one_block(rule, "action"), "block"), "custom_response").get("response_code") != 415:
        fail("encoded API bodies must be blocked with 415 before the manifest rule")
    parts = one_block(one_block(rule, "statement"), "and_statement").get("statement") or []
    if len(parts) != 2:
        fail("encoding rejection must require API path and content-encoding")
    path = one_block(parts[0], "byte_match_statement")
    header = one_block(parts[1], "size_constraint_statement")
    if path.get("search_string") != "/api/" or path.get("positional_constraint") != "STARTS_WITH" or one_block(path, "field_to_match").get("uri_path") != [{}] or path.get("text_transformation") != [{"priority": 0, "type": "NONE"}]:
        fail("encoding rejection API path changed")
    if header.get("size") != 0 or header.get("comparison_operator") != "GT" or one_block(header, "field_to_match").get("single_header") != [{"name": "content-encoding"}] or header.get("text_transformation") != [{"priority": 0, "type": "NONE"}]:
        fail("encoding rejection header match changed")


def check_manifest_body_waf(before: dict, after: dict) -> None:
    def transforms(item: dict) -> list[dict]:
        return item.get("text_transformation") or []

    def check_exception(statement: dict, path_pattern: str, method_name: str) -> None:
        matches = one_block(one_block(one_block(statement, "not_statement"), "statement"), "and_statement").get("statement") or []
        if len(matches) != 3:
            fail("each manifest exception must require path, method and JSON type")
        path = one_block(matches[0], "regex_match_statement")
        method = one_block(matches[1], "byte_match_statement")
        content_type = one_block(matches[2], "byte_match_statement")
        if path.get("regex_string") != path_pattern or one_block(path, "field_to_match").get("uri_path") != [{}] or transforms(path) != [{"priority": 0, "type": "NONE"}]:
            fail("manifest exception path or path transformation changed")
        if method.get("search_string") != method_name or method.get("positional_constraint") != "EXACTLY" or one_block(method, "field_to_match").get("method") != [{}] or transforms(method) != [{"priority": 0, "type": "NONE"}]:
            fail("manifest exception method changed")
        if content_type.get("search_string") != "application/json" or content_type.get("positional_constraint") != "EXACTLY" or one_block(content_type, "field_to_match").get("single_header") != [{"name": "content-type"}] or transforms(content_type) != [{"priority": 0, "type": "LOWERCASE"}]:
            fail("manifest exception content type changed")

    check_waf(before)
    check_waf(after)
    before_rules = {rule["name"]: rule for rule in before.get("rule", [])}
    after_rules = {rule["name"]: rule for rule in after.get("rule", [])}
    if set(after_rules) != set(before_rules) | {"RejectLargeNonManifestBody"}:
        fail("manifest change must add only the narrow body rule")
    for name in set(before_rules) - {"AWSManagedCommon", "RejectOversizeBody"}:
        if normalize_provider_empty_fields(before_rules[name]) != normalize_provider_empty_fields(after_rules[name]):
            fail(f"unrelated WAF rule {name} changed")
    for key in set(before) | set(after):
        if key not in {"rule", "association_config"} and before.get(key) != after.get(key):
            fail(f"unrelated WAF field {key} changed")

    cloudfront = one_block(one_block(after, "association_config"), "request_body")
    if one_block(cloudfront, "cloudfront").get("default_size_inspection_limit") != "KB_64":
        fail("manifest body inspection must cover 64 KiB")
    common = one_block(after_rules["AWSManagedCommon"], "statement")
    overrides = one_block(common, "managed_rule_group_statement").get("rule_action_override") or []
    if len(overrides) != 1 or overrides[0].get("name") != "SizeRestrictions_BODY":
        fail("only the managed 8-KiB body rule may be overridden")
    action = one_block(overrides[0], "action_to_use")
    if len(action.get("count") or []) != 1 or any(action.get(key) for key in ("allow", "block", "captcha", "challenge")):
        fail("managed body-size override must count, not allow")

    ceiling_rule = after_rules["RejectOversizeBody"]
    ceiling = one_block(one_block(ceiling_rule, "statement"), "size_constraint_statement")
    if ceiling_rule.get("priority") != 20 or one_block(one_block(one_block(ceiling_rule, "action"), "block"), "custom_response").get("response_code") != 413:
        fail("64-KiB ceiling must retain its priority and 413 block action")
    if ceiling.get("size") != 65536 or ceiling.get("comparison_operator") != "GT" or one_block(ceiling, "field_to_match").get("body") != [{"oversize_handling": "MATCH"}] or transforms(ceiling) != [{"priority": 0, "type": "NONE"}]:
        fail("all bodies above 64 KiB must be blocked")

    narrow = after_rules["RejectLargeNonManifestBody"]
    if narrow.get("priority") != 9 or one_block(one_block(one_block(narrow, "action"), "block"), "custom_response").get("response_code") != 413:
        fail("non-manifest body restriction must block before managed rules")
    parts = one_block(one_block(narrow, "statement"), "and_statement").get("statement") or []
    if len(parts) != 3:
        fail("non-manifest body restriction lost an exception")
    size = one_block(parts[0], "size_constraint_statement")
    if size.get("size") != 8192 or size.get("comparison_operator") != "GT" or one_block(size, "field_to_match").get("body") != [{"oversize_handling": "MATCH"}] or transforms(size) != [{"priority": 0, "type": "NONE"}]:
        fail("ordinary request bodies must retain the 8-KiB cap")
    check_exception(parts[1], "^/api/v1/demo/artifacts$", "POST")
    check_exception(parts[2], "^/api/v1/demo/artifacts/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", "PATCH")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=ALLOWED)
    parser.add_argument("plan_json", type=Path)
    parser.add_argument("--run-id", default="usrse260930")
    parser.add_argument("--control-run-id", default="usrse26r1")
    parser.add_argument("--distribution-id", default="E26XTII1H57RTX")
    parser.add_argument("--api-cache-policy-id", default="a206f89f-c17e-4bde-942a-450290111560")
    parser.add_argument("--api-origin-request-policy-id", default="07026742-00b4-4965-934e-d89eb9d7893a")
    parser.add_argument(
        "--alb-arn",
        default=(
            "arn:aws:elasticloadbalancing:us-west-2:269624229733:"
            "loadbalancer/app/k8s-oscapps-oscdemoa-5938afeb16/f59ddecd5a4a24ef"
        ),
    )
    args = parser.parse_args()
    if not args.run_id.isalnum() or not args.control_run_id.isalnum():
        fail("run IDs must be alphanumeric")
    if not args.distribution_id or not args.alb_arn.startswith(
        "arn:aws:elasticloadbalancing:us-west-2:269624229733:loadbalancer/app/"
    ):
        fail("expected distribution and same-account ALB identities")
    api_origin = f"private-demo-api-{args.run_id}"
    policy_ids = {
        "api_cache_policy_id": args.api_cache_policy_id,
        "api_origin_request_policy_id": args.api_origin_request_policy_id,
    }
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
            check_distribution(after, attached=False, distribution_id=args.distribution_id, api_origin=api_origin, **policy_ids)
            check_waf(changes[WAF]["change"]["after"])
            function = changes[FUNCTION]["change"]["after"]
            if function.get("name") != f"osc-usrse26-{args.control_run_id}-spa-rewrite":
                fail("unexpected rewrite function")
        elif args.mode == "attach":
            check_distribution(before, attached=False, distribution_id=args.distribution_id, api_origin=api_origin, **policy_ids)
            check_distribution(after, attached=True, distribution_id=args.distribution_id, api_origin=api_origin, **policy_ids)
            check_unchanged_distribution(before, after)
        else:
            check_distribution(before, attached=True, distribution_id=args.distribution_id, api_origin=api_origin, **policy_ids)
            check_distribution(after, attached=False, distribution_id=args.distribution_id, api_origin=api_origin, **policy_ids)
            check_unchanged_distribution(before, after)
    if args.mode == "origin":
        endpoint = one_block(changes[VPC_ORIGIN]["change"]["after"], "vpc_origin_endpoint_config")
        if endpoint.get("arn") != args.alb_arn or endpoint.get("origin_protocol_policy") != "http-only":
            fail("VPC origin does not target the reviewed private ALB on HTTP")
        if endpoint.get("name") != f"osc-usrse26-{args.control_run_id}-{args.run_id}-api":
            fail("VPC origin name changed")
    if args.mode == "manifest-body":
        check_manifest_body_waf(changes[WAF]["change"]["before"], changes[WAF]["change"]["after"])
    if args.mode == "reject-encoding":
        check_reject_encoding_waf(changes[WAF]["change"]["before"], changes[WAF]["change"]["after"])
    print(f"Checked {args.mode} edge plan: {len(changes)} expected changes only.")


if __name__ == "__main__":
    main()
