#!/bin/bash
oc create configmap pcscf-config -n ims --dry-run=client -o yaml | oc apply -f -
oc create configmap icscf-config -n ims --dry-run=client -o yaml | oc apply -f -
oc create configmap scscf-config -n ims --dry-run=client -o yaml | oc apply -f -
