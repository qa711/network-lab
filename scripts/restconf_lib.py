import requests
requests.packages.urllib3.disable_warnings()

import os
HOST = os.environ.get("RESTCONF_HOST", "10.99.0.3")
USER = os.environ["LAB_USER"]
PASS = os.environ["LAB_PASS"]

HEADERS = {
    "Accept": "application/yang-data+json",
    "Content-Type": "application/yang-data+json"
}

def restconf_get(path):
    url = f"https://{HOST}/restconf/data/{path}"
    resp = requests.get(url, auth=(USER, PASS), headers=HEADERS, verify=False)
    return resp.status_code, (resp.json() if resp.text else None)

def restconf_patch(path, payload):
    url = f"https://{HOST}/restconf/data/{path}"
    resp = requests.patch(url, auth=(USER, PASS), headers=HEADERS, json=payload, verify=False)
    return resp.status_code, (resp.json() if resp.text else None)
