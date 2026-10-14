from restconf_lib import restconf_get, restconf_patch

status, data = restconf_get("ietf-interfaces:interfaces")
print(status, data)

#status, data = restconf_patch(
 #   "ietf-interfaces:interfaces/interface=GigabitEthernet2"
  #  {"ietf-interfaces:interface": {"description": "--------"}}
   # "ietf-interfaces:interfaces/interface=GigabitEthernet3"
    #{"ietf-interfaces:interface": {"description": "--------"}}
#)
#print(status, data)
