---
authority: null
body_embedding_mode: "gemma"
body_tsv: "'-08':22A '-27':23A '07':25A '1':29A '1787872531267':34A '1h':51A '2026':21A '3070':82A '37.699':26A 'activ':56A 'advanc':49A 'claim':108A 'code':61A 'commit':57A,74A,87A,126A 'commitstal':12A 'common':89A 'dbos':92A 'deploy':66A,71A 'detail':37A 'edit':78A 'emit':32A 'engin':100A 'error':112A 'errorstal':16A 'executor':93A 'fals':15A,17A,19A 'fire':99A 'firestal':14A 'fix':106A 'git':3A,39A,85A,97A,120A 'git-sync':38A,84A,96A,119A 'git-sync-watchdog':2A 'har':6A 'head':46A,75A 'headunchangedhr':28A 'inspect':110A 'kind':1A 'land':60A 'lastfiredat':20A 'laststatus':30A 'lock/restart':103A 'matter':69A 'metadata.last':111A 'mobil':11A,118A 'papercup':9A,116A 'papercup-rust-mobil':8A,115A 'persistentreap':18A 'reach':81A 'reap':94A 'rescu':125A 'rescue-commit':124A 'root':90A 'routin':54A,122A 'rust':10A,117A 'ship':72A 'silent':41A 'slug':7A 'stall':42A 'strand':35A,62A,77A,131A 'stuck':95A 'sync':4A,31A,40A,86A,98A,121A 't23':24A 'tree':45A,128A 'true':13A,36A 'un':65A 'un-deploy':64A 'uncommit':63A 'urgent':133A 'watchdog':5A,43A 'wedg':101A 'won':104A 'z':27A"
escalation: "{\"kind\":\"git-sync-watchdog\",\"harness_slug\":\"papercup-rust-mobile\",\"commitStale\":true,\"fireStale\":false,\"errorStall\":false,\"persistentReap\":false,\"lastFiredAt\":\"2026-08-27T23:07:37.699Z\",\"headUnchangedHrs\":1,\"lastStatus\":\"synced\",\"emitted_at\":1787872531267,\"stranding\":true,\"detail\":\"git-sync silent stall (watchdog): the tree HEAD has not advanced in ~1h while the routine is active — commits are NOT landing (code strands uncommitted + un-deployable). Why it matters: a deploy ships only COMMITTED HEAD, so stranded edits can't reach :3070 until git-sync commits them. Common root: a DBOS executor reaping stuck git-sync fires (engine wedge — a lock/restart won't fix it). Claim it: inspect metadata.last_error on the papercup-rust-mobile git-sync routine, and rescue-commit the tree if the strand is urgent.\"}"
mtime_ms: 1787872531267
phase: "git-sync-watchdog"
risk_tier: null
supervisor_notes: null
---


