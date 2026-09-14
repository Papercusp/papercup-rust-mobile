---
authority: null
body_embedding_mode: "gemma"
body_embedding_profile: null
body_tsv: "'-09':22A '-14':23A '0':29A '17':25A '1789368125705':34A '2026':21A '3':54A '3070':77A '3h':50A '43.250':26A 'activ':51A 'claim':103A 'commit':69A,82A,121A 'commitstal':12A 'common':84A 'cron':52A 'dbos':87A 'deploy':66A 'detail':37A 'edit':73A 'emit':32A 'engin':95A 'error':107A 'errorstal':16A 'everi':53A 'executor':88A 'fals':13A,17A,19A 'fire':48A,94A 'firestal':14A 'fix':101A 'git':3A,39A,80A,92A,115A 'git-sync':38A,79A,91A,114A 'git-sync-watchdog':2A 'har':6A 'head':70A 'headunchangedhr':28A 'inspect':105A 'kind':1A 'lastfiredat':20A 'laststatus':30A 'lock/restart':98A 'matter':64A 'metadata.last':106A 'min':55A 'mobil':11A,113A 'noth':31A 'papercup':9A,111A 'papercup-rust-mobil':8A,110A 'persistentreap':18A 'reach':76A 'reap':89A 'rescu':120A 'rescue-commit':119A 'root':85A 'routin':45A,117A 'run':60A 'rust':10A,112A 'scheduler/engine':57A 'ship':67A 'silent':41A 'slug':7A 'stall':42A 'strand':35A,72A,126A 'stuck':90A 'sync':4A,40A,81A,93A,116A 't03':24A 'tree':123A 'true':15A,36A 'urgent':128A 'watchdog':5A,43A 'wedg':96A 'won':99A 'z':27A"
escalation: "{\"kind\":\"git-sync-watchdog\",\"harness_slug\":\"papercup-rust-mobile\",\"commitStale\":false,\"fireStale\":true,\"errorStall\":false,\"persistentReap\":false,\"lastFiredAt\":\"2026-09-14T03:17:43.250Z\",\"headUnchangedHrs\":0,\"lastStatus\":\"nothing\",\"emitted_at\":1789368125705,\"stranding\":true,\"detail\":\"git-sync silent stall (watchdog): the routine has not FIRED in ~3h (active, cron every 3 min) — the scheduler/engine is not running it. Why it matters: a deploy ships only COMMITTED HEAD, so stranded edits can't reach :3070 until git-sync commits them. Common root: a DBOS executor reaping stuck git-sync fires (engine wedge — a lock/restart won't fix it). Claim it: inspect metadata.last_error on the papercup-rust-mobile git-sync routine, and rescue-commit the tree if the strand is urgent.\"}"
mtime_ms: 1789368125705
phase: "git-sync-watchdog"
risk_tier: null
supervisor_notes: null
---


