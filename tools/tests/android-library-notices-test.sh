#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Compare the maintained collector's actual output with Gradle's resolved graph.
# This guards graph coverage; native/model notices and license clearance are separate.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
JAVA_HOME="$("$ROOT/tools/build-scripts/resolve-java-home.sh")"
export JAVA_HOME

cat > "$TMP/notices-test.gradle" <<'GRADLE'
import groovy.json.JsonSlurper
import org.gradle.api.artifacts.component.ModuleComponentIdentifier
import java.security.MessageDigest

def fixtureRepo = System.getProperty('papercup.notices.fixtureRepo')
if (fixtureRepo) {
    gradle.settingsEvaluated { settings ->
        settings.dependencyResolutionManagement.repositories.maven { url = new File(fixtureRepo).toURI() }
    }
}
gradle.projectsEvaluated {
    def app = gradle.rootProject.project(':app')
    if (fixtureRepo) app.dependencies.add('implementation', 'fixture.notices:metadata-cache-probe:1.0')
    app.tasks.register('verifyReleaseLibraryMetadata') {
        dependsOn ':app:prepareLibraryDefinitionsRelease', ':app:prepareLibraryDefinitionsDebug'
        doLast {
            ['release', 'debug'].each { variant ->
            def source = new File(app.buildDir, "generated/aboutLibraries/$variant/res/raw/aboutlibraries.json")
            assert source.isFile(): 'Generated release library resource is missing'
            def document = new JsonSlurper().parse(source)
            def expected = app.configurations.getByName("${variant}RuntimeClasspath").incoming.resolutionResult.allComponents
                .findAll { it.id instanceof ModuleComponentIdentifier }
                .collectEntries { [("${it.id.group}:${it.id.module}".toString()): it.id.version] }
            assert !expected.isEmpty(): 'Release dependency graph is empty'
            def config = new File(app.projectDir, '../config')
            def provenance = new JsonSlurper().parse(new File(config, 'SOURCES.json'))
            def supplements = provenance.licenses.collectEntries { provenanceRow ->
                def definition = new JsonSlurper().parse(new File(app.projectDir, "../../${provenanceRow.file}"))
                assert definition.hash == provenanceRow.hash: "Supplement license ID differs: ${provenanceRow.file}"
                def digest = MessageDigest.getInstance('SHA-256').digest(definition.content.getBytes('UTF-8')).encodeHex().toString()
                assert digest == provenanceRow.contentSha256: "Supplement content differs from retained source: ${provenanceRow.file}"
                assert provenanceRow.sourceUrl?.startsWith('https://') && provenanceRow.sourceSha256 ==~ /[0-9a-f]{64}/:
                    "Supplement source provenance is missing: ${provenanceRow.file}"
                [(provenanceRow.hash): [definition: definition, source: provenanceRow]]
            }
            assert supplements.size() == 5: 'The five reviewed link-only license supplements are incomplete'
            def validate = { data ->
                assert data.libraries instanceof List && !data.libraries.isEmpty(): 'Library metadata is empty'
                def rows = data.libraries.collectEntries { [(it.uniqueId): it] }
                assert rows.size() == data.libraries.size(): 'Duplicate library IDs'
                assert rows.keySet() == expected.keySet(): "Notice module population differs: $variant"
                expected.each { id, version ->
                    assert rows.containsKey(id): "Release module missing: $id"
                    assert rows[id].artifactVersion == version: "Release module version differs: $id"
                }
                assert !rows.containsKey('junit:junit'): 'Test-only JUnit leaked into release notices'
                if (variant == 'release') assert !rows.containsKey('androidx.compose.ui:ui-tooling'): 'Debug tooling leaked into release notices'
                assert rows.containsKey('fixture.notices:metadata-cache-probe') == !!fixtureRepo:
                    'Cached notice resource retained or omitted the graph-transition fixture'
                data.libraries.each { row ->
                    row.licenses.each { id ->
                        assert data.licenses.containsKey(id): "Unresolved license reference: $id"
                        assert data.licenses[id].content?.trim(): "Referenced license has no offline text: $id"
                    }
                }
                supplements.each { id, supplement ->
                    assert data.licenses[id]?.content == supplement.definition.content:
                        "Supplement was omitted or changed by collector: $id"
                    assert data.licenses[id].name == supplement.definition.name:
                        "Supplement name was not preserved: $id"
                    supplement.source.modules.each { ref ->
                        if (expected.containsKey(ref.module)) {
                            assert expected[ref.module] == ref.version: "Supplement needs version review: ${ref.module}"
                            assert rows[ref.module].licenses.contains(id): "Module lost supplemental notice: ${ref.module}"
                        }
                    }
                }
                def sipText = data.licenses['fa7f33c49aa6110f3cedeb2975e140e0'].content
                assert sipText.contains('NIST MAKES NO WARRANTY') && sipText.contains('BEA Systems') &&
                    sipText.contains('Sun Microsystems') && sipText.contains('Use is subject to license terms'):
                    'JAIN SIP public-domain label lost its distinct API copyright notice'
                ['Apache-2.0', 'MIT'].each { id ->
                    assert data.licenses[id]?.content?.trim(): "Standard license text missing: $id"
                }
            }
            validate(document)
            def expectRejected = { label, mutation ->
                def changed = new JsonSlurper().parse(source)
                mutation(changed)
                boolean rejected = false
                try { validate(changed) } catch (AssertionError expectedFailure) { rejected = true }
                assert rejected: "Metadata guard accepted $label"
            }
            def firstId = expected.keySet().first()
            expectRejected('an omitted release module') { it.libraries.removeAll { row -> row.uniqueId == firstId } }
            expectRejected('a stale module version') { it.libraries.find { row -> row.uniqueId == firstId }.artifactVersion = 'fixture-stale' }
            expectRejected('a test-only dependency') { it.libraries.add([uniqueId: 'junit:junit', licenses: []]) }
            expectRejected('missing standard license text') { it.licenses['Apache-2.0'].remove('content') }
            supplements.each { id, supplement ->
                expectRejected("missing supplemental text $id") { it.licenses[id].remove('content') }
                expectRejected("substituted supplemental text $id") { it.licenses[id].content = 'A different complete license' }
                def module = supplement.source.modules.find { expected.containsKey(it.module) }.module
                expectRejected("unlinked supplemental text $id") { it.libraries.find { row -> row.uniqueId == module }.licenses.remove(id) }
            }
            expectRejected('JAIN SIP API copyright removed while NIST conditions remain') {
                def id = 'fa7f33c49aa6110f3cedeb2975e140e0'
                it.licenses[id].content = it.licenses[id].content.split('JAIN SIP API copyright notice')[0]
            }
            println "$variant library metadata PASS: ${expected.size()} resolved modules, ${document.libraries.size()} records; five offline supplements; twenty rejecting controls"
            }
        }
    }
}
GRADLE

"$ROOT/android/gradlew" -p "$ROOT/android" --console=plain \
    --init-script "$TMP/notices-test.gradle" :app:verifyReleaseLibraryMetadata

# Exercise the actual producer's up-to-date behavior across an add/remove
# transition. The Maven fixture stays private to this test's temporary repo;
# no production dependency or network service is added.
mkdir -p "$TMP/repository/fixture/notices/metadata-cache-probe/1.0"
cat > "$TMP/repository/fixture/notices/metadata-cache-probe/1.0/metadata-cache-probe-1.0.pom" <<'POM'
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion><groupId>fixture.notices</groupId>
  <artifactId>metadata-cache-probe</artifactId><version>1.0</version>
  <name>Notice cache regression fixture</name>
  <licenses><license><name>Apache-2.0</name><url>https://www.apache.org/licenses/LICENSE-2.0.txt</url></license></licenses>
</project>
POM
python3 - "$TMP/repository/fixture/notices/metadata-cache-probe/1.0/metadata-cache-probe-1.0.jar" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], 'w') as archive:
    archive.writestr('META-INF/MANIFEST.MF', 'Manifest-Version: 1.0\n')
PY
"$ROOT/android/gradlew" -p "$ROOT/android" --console=plain \
    "-Dpapercup.notices.fixtureRepo=$TMP/repository" \
    --init-script "$TMP/notices-test.gradle" :app:verifyReleaseLibraryMetadata
"$ROOT/android/gradlew" -p "$ROOT/android" --console=plain \
    --init-script "$TMP/notices-test.gradle" :app:verifyReleaseLibraryMetadata
echo 'Release notice collector cached add/remove graph transitions PASS'
