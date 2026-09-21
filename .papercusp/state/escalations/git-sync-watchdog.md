---
authority: null
body_embedding_mode: "gemma"
body_embedding_profile: null
body_tsv: "'-09':22A '-20':23A '0':29A '1789948538924':34A '2':53A '2026':21A '26':25A '45.281':26A '600000ms':73A 'action':64A 'advanc':100A 'assum':152A 'blip':60A 'bridg':149A 'cannot':142A 'code':107A 'code-strand':106A 'commit':114A 'commitstal':12A 'compar':155A 'consecut':54A,89A 'current':164A 'deadlin':76A 'detail':37A 'emit':32A 'error':31A,121A 'errorstal':16A 'fail':96A,148A 'fals':13A,15A,19A,36A 'fault':42A,51A,87A 'firestal':14A 'first':132A 'fix':134A 'git':3A,39A,46A,62A,70A,81A,129A 'git-sync':38A,45A,61A,80A,128A 'git-sync-watchdog':2A 'har':6A 'head':98A,158A 'headunchangedhr':28A 'idl':74A 'kind':1A 'lastfiredat':20A 'laststatus':30A 'leg':93A,136A 'live':75A 'matter':79A 'merg':143A 'metadata.last':120A 'mobil':11A,127A 'move':118A 'name':138A 'noth':165A 'one':92A 'origin':160A,162A 'papercup':9A,125A 'papercup-rust-mobil':8A,124A 'persist':41A,57A 'persistentreap':18A 'push':146A 'read':119A 'record':49A,84A 'reject':145A 'reliabl':95A 'rescu':113A 'rescue-commit':112A 'routin':131A 'run':69A 'run-git-sync':68A 'rust':10A,126A 'slug':7A 'stall':109A 'strand':35A,108A,154A,167A 'streak':43A 'submodul':140A 'sweep':56A,90A 'sync':4A,40A,47A,63A,71A,82A,130A 't23':24A 'time':65A 'tree':157A 'true':17A 'verifi':150A 'watchdog':5A,44A,55A 'wrong':117A 'z':27A"
escalation: "{\"kind\":\"git-sync-watchdog\",\"harness_slug\":\"papercup-rust-mobile\",\"commitStale\":false,\"fireStale\":false,\"errorStall\":true,\"persistentReap\":false,\"lastFiredAt\":\"2026-09-20T23:26:45.281Z\",\"headUnchangedHrs\":0,\"lastStatus\":\"error\",\"emitted_at\":1789948538924,\"stranding\":false,\"detail\":\"git-sync persistent fault streak (watchdog): git-sync has recorded a FAULT on 2 consecutive watchdog sweeps (persistent, not a blip): \\\"git-sync action timed out during run-git-sync after 600000ms (idle liveness deadline)\\\". Why it matters: git-sync has recorded the SAME fault on consecutive sweeps, so one leg is reliably failing — but HEAD is advancing, so this is NOT the code-stranding stall and a rescue-commit is the WRONG move. Read metadata.last_error on the papercup-rust-mobile git-sync routine FIRST and fix the leg it names (a submodule that cannot merge, a rejected push, a failing bridge). Verify before assuming a strand: compare the tree HEAD against origin/<branch> — if origin is current, nothing is stranded.\"}"
mtime_ms: 1789948538924
phase: "git-sync-watchdog"
risk_tier: null
supervisor_notes: null
---


