---
authority: null
body_embedding_mode: "gemma"
body_tsv: "'1787845025631':63A '33':19A,75A 'admiss':33A,37A 'admissionpersistenceerror':35A 'attent':69A 'block':49A 'canon':26A 'commit':51A,78A 'config':24A 'consecut':16A,76A 'could':39A,52A 'declar':47A,58A 'detail':64A 'dirti':55A 'durabl':36A 'emit':61A 'error':5A,17A,20A 'fail':30A,34A,74A 'failur':15A,72A 'generat':46A 'git':3A,66A 'git-sync':65A 'git-sync-error':2A 'har':6A 'inspect':54A 'kind':1A 'messag':25A,45A 'mobil':11A 'need':68A 'origin':81A 'overs':60A 'papercup':9A 'papercup-rust-mobil':8A 'path':56A 'persist':42A 'push':14A,71A,73A 'push-failur':13A,70A 'reach':80A 'reason':12A 'record':38A 'regener':59A 'repair':48A 'rust':10A 'scope':21A,43A 'sidecar':32A 'slug':7A 'spawner':31A 'submodul':23A,27A 'submodule-config':22A 'superproject':44A 'sync':4A,29A,67A 'tick':18A,77A 'url':28A"
escalation: "{\"kind\":\"git-sync-error\",\"harness_slug\":\"papercup-rust-mobile\",\"reasons\":[\"push-failure\"],\"consecutive_error_ticks\":33,\"errors\":[{\"scope\":\"submodule-config\",\"message\":\"canonical submodule URL sync failed: spawner sidecar admission failed: AdmissionPersistenceError: durable admission record could not be persisted\"},{\"scope\":\"superproject\",\"message\":\"generated declaration repair blocked the commit: could not inspect dirty paths before declaration regeneration\"}],\"oversized\":[],\"emitted_at\":1787845025631,\"detail\":\"git-sync needs attention: push-failure — push failed 33 consecutive ticks (commits NOT reaching origin)\"}"
mtime_ms: 1787845025631
phase: "git-sync"
risk_tier: null
supervisor_notes: null
---


