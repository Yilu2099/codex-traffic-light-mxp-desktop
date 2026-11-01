"""Read-only union of server audit JSONL; never infer usage from account totals."""
import collections
import json
import sys


def reconcile(rows):
    groups = {}
    for row in rows:
        event = row.get('event', {})
        if event.get('source') != 'native_receipt_audit' or event.get('reason') not in ('confirmed', 'snapshot'):
            continue
        account, key = event.get('account'), event.get('key')
        if not account or not key:
            continue  # Unscoped records cannot be combined across devices/accounts.
        group = groups.setdefault((row['userId'], account), {'requests': {}, 'conflicts': set(), 'devices': collections.defaultdict(dict), 'scans': {}})
        values = event['values']
        if event['reason'] == 'snapshot':
            identity = (row['deviceId'], event['eventAt'][:10])
            old = group['scans'].get(identity)
            if not old or event['at'] > old['at']:
                group['scans'][identity] = event
            continue
        vector = (event['eventAt'], *(values.get(k, 0) for k in ('input', 'cached', 'output', 'reasoning', 'cacheWrite')))
        prior = group['devices'][row['deviceId']].get(key)
        if prior is not None and prior != vector:
            group['conflicts'].add(key)
        group['devices'][row['deviceId']][key] = vector
        prior = group['requests'].get(key)
        if prior is not None and prior != vector:
            group['conflicts'].add(key)
        group['requests'][key] = vector
    result = []
    for (user, account), group in sorted(groups.items()):
        days = collections.defaultdict(lambda: {'requests': 0, 'tokens': 0})
        accepted = {key: v for key, v in group['requests'].items() if key not in group['conflicts']}
        for vector in accepted.values():
            day = days[vector[0][:10]]
            day['requests'] += 1
            day['tokens'] += vector[1] + vector[3]
        per_device = {device: {'requests': len(records), 'tokens': sum(v[1] + v[3] for v in records.values())}
                      for device, records in sorted(group['devices'].items())}
        occurrences = collections.Counter(key for records in group['devices'].values() for key in records)
        scans = []
        for (device, day), event in sorted(group['scans'].items()):
            records = [v for v in group['devices'].get(device, {}).values() if v[0][:10] == day]
            v = event['values']
            scans.append({'deviceId': device, 'day': day, 'scanComplete': v.get('auditComplete') == 1,
                          'receivedRequestsMatch': len(records) == v.get('receiptCount')
                          and sum(r[1] + r[3] for r in records) == v.get('receiptTokens')})
        result.append({'userId': user, 'account': account, 'devices': per_device,
                       'sourceScans': scans,
                       'days': dict(sorted(days.items())), 'requestCount': len(accepted),
                       'tokens': sum(day['tokens'] for day in days.values()),
                       'copiedRequests': sum(occurrences[key] - 1 for key in accepted),
                       'conflictingRequests': len(group['conflicts'])})
    return {'scope': 'identified-native-request-subtotal', 'accountWideComplete': False, 'accounts': result}


if __name__ == '__main__':
    with open(sys.argv[1]) as source:
        print(json.dumps(reconcile(json.loads(line) for line in source if line.strip()), ensure_ascii=False, indent=2))
