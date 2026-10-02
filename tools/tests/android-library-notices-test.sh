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
        dependsOn ':app:prepareLibraryDefinitionsRelease'
        doLast {
            def source = new File(app.buildDir, 'generated/aboutLibraries/release/res/raw/aboutlibraries.json')
            assert source.isFile(): 'Generated release library resource is missing'
            def document = new JsonSlurper().parse(source)
            def expected = app.configurations.releaseRuntimeClasspath.incoming.resolutionResult.allComponents
                .findAll { it.id instanceof ModuleComponentIdentifier }
                .collectEntries { [("${it.id.group}:${it.id.module}".toString()): it.id.version] }
            assert !expected.isEmpty(): 'Release dependency graph is empty'
            def validate = { data ->
                assert data.libraries instanceof List && !data.libraries.isEmpty(): 'Library metadata is empty'
                def rows = data.libraries.collectEntries { [(it.uniqueId): it] }
                assert rows.size() == data.libraries.size(): 'Duplicate library IDs'
                expected.each { id, version ->
                    assert rows.containsKey(id): "Release module missing: $id"
                    assert rows[id].artifactVersion == version: "Release module version differs: $id"
                }
                assert !rows.containsKey('junit:junit'): 'Test-only JUnit leaked into release notices'
                assert !rows.containsKey('androidx.compose.ui:ui-tooling'): 'Debug tooling leaked into release notices'
                assert rows.containsKey('fixture.notices:metadata-cache-probe') == !!fixtureRepo:
                    'Cached notice resource retained or omitted the graph-transition fixture'
                data.libraries.each { row ->
                    row.licenses.each { id ->
                        assert data.licenses.containsKey(id): "Unresolved license reference: $id"
                    }
                }
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
            println "Release library metadata PASS: ${expected.size()} resolved modules, ${document.libraries.size()} records; four rejecting controls"
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
