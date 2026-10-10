#!/usr/bin/env python3
"""Unauthenticated checks against the deployed HTTPS gateway; writes no user data."""
import argparse
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("base_url")
parser.add_argument("--maintenance", action="store_true",
                    help="expect the deliberately stopped upstream (503), not production auth (401)")
args = parser.parse_args()
upstream = 503 if args.maintenance else 401

def check(method, path, expected, body=None):
    command = ["curl", "--connect-timeout", "5", "--max-time", "15", "--silent",
               "--show-error", "--output", "/dev/null", "--write-out", "%{http_code}",
               "--request", method, "--header", "Content-Type: application/json"]
    if body is not None:
        command += ["--data-binary", "@-"]
    result = subprocess.run(command + [args.base_url.rstrip("/") + path],
                            input=body, capture_output=True, check=True)
    status = int(result.stdout)
    assert status == expected, f"{method} {path}: expected {expected}, received {status}"
    print(f"PASS {method} {path}: {status}", flush=True)

check("GET", "/petlink/v2/me", upstream)
check("PATCH", "/petlink/v2/me", upstream, b'{}')
check("PATCH", "/petlink/v2/contacts/edge-fixture/policy", upstream, b'{}')
check("PATCH", "/petlink/v3/contacts/edge-fixture/avatar-policy", upstream, b'{}')
check("PUT", "/petlink/health", 403)
check("GET", "/not-a-backend-route", 404)
check("POST", "/petlink/v2/auth/google/begin", 413, b'x' * 40000)
