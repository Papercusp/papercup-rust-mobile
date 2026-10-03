#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Compare the maintained collector's actual output with Gradle's resolved graph.
# This guards graph coverage and selected upstream notices; complete native/model
# coverage and license clearance remain separate release requirements.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
JAVA_HOME="$("$ROOT/tools/build-scripts/resolve-java-home.sh")"
export JAVA_HOME

python3 - "$ROOT/Cargo.lock" "$TMP/cargo-registry.json" <<'PY'
import hashlib, json, pathlib, sys, tomllib
source = pathlib.Path(sys.argv[1]).read_bytes()
packages = [p for p in tomllib.loads(source.decode())['package'] if p.get('source')]
assert all(p['source'] == 'registry+https://github.com/rust-lang/crates.io-index' for p in packages)
pathlib.Path(sys.argv[2]).write_text(json.dumps({'sha256': hashlib.sha256(source).hexdigest(), 'packages': packages}))
PY

cat > "$TMP/notices-test.gradle" <<'GRADLE'
import groovy.json.JsonSlurper
import org.gradle.api.artifacts.component.ModuleComponentIdentifier
import java.security.MessageDigest

// Keep add/remove fixtures out of application packaging outputs, including
// when this maintained check runs from the automatic pre-push gate.
def noticeBuildDir = System.getProperty('papercup.notices.buildDir')
assert noticeBuildDir: 'Notice regression requires isolated outputs'
gradle.beforeProject { project ->
    if (project.path == ':app') project.layout.buildDirectory.set(new File(noticeBuildDir))
}

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
            def isolated = new File(noticeBuildDir).canonicalFile
            assert app.buildDir.canonicalFile == isolated: 'Notice fixture escaped isolated build directory'
            ['release', 'debug'].each { variant ->
            def producer = app.tasks.getByName("prepareLibraryDefinitions${variant.capitalize()}")
            assert producer.outputs.files.files.every { it.canonicalPath.startsWith(isolated.path + File.separator) }:
                'Notice producer output escaped isolated build directory'
            def source = new File(app.buildDir, "generated/aboutLibraries/$variant/res/raw/aboutlibraries.json")
            assert source.isFile(): 'Generated release library resource is missing'
            def document = new JsonSlurper().parse(source)
            def expected = app.configurations.getByName("${variant}RuntimeClasspath").incoming.resolutionResult.allComponents
                .findAll { it.id instanceof ModuleComponentIdentifier }
                .collectEntries { [("${it.id.group}:${it.id.module}".toString()): it.id.version] }
            assert !expected.isEmpty(): 'Release dependency graph is empty'
            def config = new File(app.projectDir, '../config')
            def rust = new JsonSlurper().parse(new File(config, 'RUST-SOURCES.json'))
            def lockedRust = new JsonSlurper().parse(new File(System.getProperty('papercup.notices.cargoRegistry')))
            def validateRustSource = { sourceInventory ->
                assert sourceInventory.cargoLockSha256 == lockedRust.sha256: 'Rust notices are stale for Cargo.lock'
                def declared = sourceInventory.packages.collectEntries { [("${it.name}:${it.version}".toString()): it.packageChecksum] }
                def locked = lockedRust.packages.collectEntries { [("${it.name}:${it.version}".toString()): it.checksum] }
                assert declared.size() == sourceInventory.packages.size() && declared == locked:
                    'Rust notice source/checksum population differs from Cargo.lock'
            }
            validateRustSource(rust)
            def rustLibraries = rust.packages.collectEntries { pkg ->
                def definition = new JsonSlurper().parse(new File(app.projectDir, "../../${pkg.libraryFile}"))
                assert definition.uniqueId == "rust:${pkg.name}:${pkg.version}".toString() && definition.artifactVersion == pkg.version:
                    'Rust collector definition lost its exact package identity'
                assert definition.description.contains("declared license: ${pkg.declaredLicense ?: 'see declared license file'}"):
                    'Rust collector definition lost the source license declaration'
                assert definition.licenses.toSet() == pkg.texts.collect { it.licenseId }.toSet() && !definition.licenses.isEmpty():
                    'Rust collector definition lost a notice reference'
                [(definition.uniqueId): definition]
            }
            def rustLicenses = rust.packages.collectMany { it.texts }.collectEntries { text ->
                def definition = new JsonSlurper().parse(new File(app.projectDir, "../../${text.licenseFile}"))
                assert definition.hash == text.licenseId: 'Rust notice text ID differs from source receipt'
                def digest = MessageDigest.getInstance('SHA-256').digest(definition.content.getBytes('UTF-8')).encodeHex().toString()
                assert digest == text.sha256 && definition.content.trim(): 'Rust notice text differs from source bytes'
                [(text.licenseId): definition]
            }
            assert rustLibraries.size() == rust.verifiedRegistryPackages && rustLicenses.size() == rust.uniqueNoticeTexts:
                'Rust collector source receipt counts differ from definitions'
            def configRustIds = new File(config, 'libraries').listFiles().findAll { it.name.startsWith('rust-') }.collect {
                new JsonSlurper().parse(it).uniqueId
            }.toSet()
            assert configRustIds == rustLibraries.keySet(): 'Stale or omitted Rust collector definition'
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
            assert supplements.size() == 8: 'The five license texts and three selected upstream attributions are incomplete'
            def upstreamNotices = [
                'io.livekit:livekit-android': 'papercusp-livekit-notice',
                'net.java.dev.jna:jna': 'papercusp-jna-libffi',
                'androidx.graphics:graphics-path': 'papercusp-graphics-path-notice'
            ]
            upstreamNotices.each { module, id ->
                def supplement = supplements[id]
                assert supplement: "Selected upstream notice is missing: $module"
                assert supplement.source.sourceRevision ==~ /[0-9a-f]{40}/:
                    "Selected upstream notice revision is missing: $module"
                if (module != 'androidx.graphics:graphics-path') {
                    assert supplement.source.sourceSha256 == supplement.source.contentSha256:
                        "Selected upstream notice is not byte-for-byte: $module"
                } else {
                    // This attribution is derived from ten full source headers,
                    // rather than claiming an original upstream NOTICE file.
                    assert supplement.source.sourceEntries.size() == 10:
                        'Graphics Path native source attribution population differs'
                    assert supplement.source.sourceEntries.every {
                        it.sha256 ==~ /[0-9a-f]{64}/ && it.headerSha256 ==~ /[0-9a-f]{64}/
                    }: 'Graphics Path attribution lost pinned source/header hashes'
                    assert supplement.source.extraction.contains('not an original upstream NOTICE'):
                        'Graphics Path derived attribution lost its extraction scope'
                }
                def override = new JsonSlurper().parse(new File(app.projectDir, "../../${supplement.source.librariesFile}"))
                assert override.uniqueId == module && override.licenses == [id]:
                    "Selected upstream notice library override differs: $module"
            }
            def validate = { data ->
                assert data.libraries instanceof List && !data.libraries.isEmpty(): 'Library metadata is empty'
                def rows = data.libraries.collectEntries { [(it.uniqueId): it] }
                assert rows.size() == data.libraries.size(): 'Duplicate library IDs'
                assert rows.keySet() == expected.keySet() + rustLibraries.keySet(): "Notice module/source population differs: $variant"
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
                upstreamNotices.each { module, id ->
                    assert rows[module].licenses.containsAll(['Apache-2.0', id]):
                        "Selected upstream notice replaced the original license: $module"
                }
                assert rows['net.java.dev.jna:jna'].licenses.contains('LGPL-2.1-or-later'):
                    'JNA upstream notice lost the existing alternative license'
                rustLibraries.each { id, definition ->
                    assert rows[id].artifactVersion == definition.artifactVersion && rows[id].description == definition.description:
                        "Rust collector changed package identity or scope: $id"
                    assert rows[id].licenses.toSet() == definition.licenses.toSet(): "Rust collector lost notice references: $id"
                }
                rustLicenses.each { id, definition ->
                    assert data.licenses[id]?.content == definition.content && data.licenses[id].name == definition.name:
                        "Rust collector changed source notice text: $id"
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
            def firstRustId = rustLibraries.keySet().first()
            def firstRustLicense = rustLicenses.keySet().first()
            expectRejected('an omitted Rust source package') { it.libraries.removeAll { row -> row.uniqueId == firstRustId } }
            expectRejected('a stale Rust source version') { it.libraries.find { row -> row.uniqueId == firstRustId }.artifactVersion = 'stale' }
            expectRejected('an unlinked Rust notice') { it.libraries.find { row -> row.uniqueId == firstRustId }.licenses.clear() }
            expectRejected('changed Rust text') { it.licenses[firstRustLicense].content = 'Substituted text' }
            expectRejected('missing Rust text') { it.licenses.remove(firstRustLicense) }
            ['lock', 'checksum'].each { defect ->
                def changed = new JsonSlurper().parse(new File(config, 'RUST-SOURCES.json'))
                if (defect == 'lock') changed.cargoLockSha256 = '0' * 64
                else changed.packages.first().packageChecksum = '0' * 64
                boolean rejected = false
                try { validateRustSource(changed) } catch (AssertionError expectedFailure) { rejected = true }
                assert rejected: "Rust source guard accepted stale $defect"
            }
            println "$variant library metadata PASS: ${expected.size()} resolved modules, ${rustLibraries.size()} locked Rust source packages, ${document.libraries.size()} records; eight offline supplements and ${rustLicenses.size()} Rust texts; thirty-six rejecting controls"
            }
        }
    }
}
GRADLE

"$ROOT/android/gradlew" -p "$ROOT/android" --console=plain \
    "-Dpapercup.notices.cargoRegistry=$TMP/cargo-registry.json" \
    "-Dpapercup.notices.buildDir=$TMP/build" \
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
    "-Dpapercup.notices.cargoRegistry=$TMP/cargo-registry.json" \
    "-Dpapercup.notices.buildDir=$TMP/build" \
    "-Dpapercup.notices.fixtureRepo=$TMP/repository" \
    --init-script "$TMP/notices-test.gradle" :app:verifyReleaseLibraryMetadata
"$ROOT/android/gradlew" -p "$ROOT/android" --console=plain \
    "-Dpapercup.notices.cargoRegistry=$TMP/cargo-registry.json" \
    "-Dpapercup.notices.buildDir=$TMP/build" \
    --init-script "$TMP/notices-test.gradle" :app:verifyReleaseLibraryMetadata
echo 'Release notice collector isolated cached add/remove graph transitions PASS'
