import requests
requests.packages.urllib3.disable_warnings()

import os
HOST = os.environ.get("RESTCONF_HOST", "10.99.250.250")
USER = os.environ["LAB_USER"]
PASS = os.environ["LAB_PASS"]

headers = {
    "Accept": "application/yang-data+json",
    "Content-Type": "application/yang-data+json"
}

payload = {
    "ietf-interfaces:interface": {
        "description": "SET-BY-PYTHON"
    }
}

url = f"https://{HOST}/restconf/data/ietf-interfaces:interfaces/interface=GigabitEthernet2"

resp = requests.patch(url, auth=(USER, PASS), headers=headers, json=payload, verify=False)
print("PATCH status:", resp.status_code)

if resp.status_code not in (200, 204):
    print("Something went wrong:", resp.text)

# separate GET to prove it actually took
check = requests.get(url, auth=(USER, PASS), headers=headers, verify=False)
print("Description now:", check.json()["ietf-interfaces:interface"]["description"])
