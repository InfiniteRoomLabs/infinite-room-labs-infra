# Phase 1: Gradle Plugin (Shell-out to Terragrunt) Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a Gradle plugin that models Terraform/Terragrunt infrastructure as a Gradle multi-project build with DAG-aware execution, replacing raw `terragrunt` CLI usage with `./gradlew :<env>:<provider>:<resource-group>:<action>` commands.

**Architecture:** A Gradle settings plugin registers subprojects from a Kotlin DSL declaration. A project plugin adds infrastructure configuration (state backend, providers, dependencies) and registers Terragrunt task types (init, validate, plan, apply, destroy, output) per subproject. The engine shells out to `terragrunt` in each subproject's directory. Gradle's task DAG handles dependency ordering and parallel execution.

**Tech Stack:** Kotlin 2.1.x, Gradle 8.x (latest), JUnit 5, Gradle TestKit, Java 21 (Temurin)

**Proving ground:** `~/projects/infinite-room-labs/infinite-room-labs-infra` -- existing Terragrunt monorepo with 6 resource groups across 3 environments.

**New repo location:** `~/projects/infinite-room-labs/irl-gradle-plugin`

---

## Task 1: Scaffold the Plugin Project

**Files:**
- Create: `irl-gradle-plugin/settings.gradle.kts`
- Create: `irl-gradle-plugin/build.gradle.kts`
- Create: `irl-gradle-plugin/gradle.properties`
- Create: `irl-gradle-plugin/src/main/kotlin/com/infiniteroomlabs/gradle/IrlInfrastructurePlugin.kt`
- Create: `irl-gradle-plugin/src/main/kotlin/com/infiniteroomlabs/gradle/IrlSettingsPlugin.kt`
- Test: `irl-gradle-plugin/src/test/kotlin/com/infiniteroomlabs/gradle/IrlInfrastructurePluginTest.kt`

**Step 1: Create the repo and initialize Gradle wrapper**

```bash
cd ~/projects/infinite-room-labs
mkdir -p irl-gradle-plugin
cd irl-gradle-plugin
git init

# Generate the Gradle wrapper (use latest stable)
# Download gradle-wrapper.jar via gradle init or manually
gradle init --type basic --dsl kotlin
```

Note: Since `gradle` is not installed globally, use `sdk install gradle` first or download the wrapper JAR manually. The `gradle init` command creates the wrapper. After this, all subsequent commands use `./gradlew`.

**Step 2: Configure the build**

Replace the generated `build.gradle.kts` with:

```kotlin
plugins {
    `java-gradle-plugin`
    alias(libs.plugins.kotlin.jvm)
}

group = "com.infiniteroomlabs"
version = "0.1.0-SNAPSHOT"

repositories {
    mavenCentral()
}

dependencies {
    testImplementation(libs.junit.jupiter)
    testImplementation(libs.junit.jupiter.params)
    testRuntimeOnly(libs.junit.platform.launcher)
}

gradlePlugin {
    plugins {
        create("infrastructure") {
            id = "com.infiniteroomlabs.infrastructure"
            implementationClass = "com.infiniteroomlabs.gradle.IrlInfrastructurePlugin"
        }
        create("infrastructureSettings") {
            id = "com.infiniteroomlabs.infrastructure.settings"
            implementationClass = "com.infiniteroomlabs.gradle.IrlSettingsPlugin"
        }
    }
}

kotlin {
    jvmToolchain(21)
}

tasks.test {
    useJUnitPlatform()
}
```

Create `settings.gradle.kts`:

```kotlin
rootProject.name = "irl-gradle-plugin"

dependencyResolution {
    versionCatalogs {
        create("libs") {
            // Versions will be set in gradle/libs.versions.toml
        }
    }
}
```

Create `gradle/libs.versions.toml` (use latest stable versions at time of implementation):

```toml
[versions]
kotlin = "2.1.10"    # check latest
junit = "5.11.4"     # check latest

[libraries]
junit-jupiter = { module = "org.junit.jupiter:junit-jupiter", version.ref = "junit" }
junit-jupiter-params = { module = "org.junit.jupiter:junit-jupiter-params", version.ref = "junit" }
junit-platform-launcher = { module = "org.junit.platform:junit-platform-launcher" }

[plugins]
kotlin-jvm = { id = "org.jetbrains.kotlin.jvm", version.ref = "kotlin" }
```

Create `gradle.properties`:

```properties
org.gradle.parallel=true
org.gradle.caching=true
org.gradle.jvmargs=-Xmx512m
```

**Step 3: Create stub plugin classes**

`src/main/kotlin/com/infiniteroomlabs/gradle/IrlInfrastructurePlugin.kt`:

```kotlin
package com.infiniteroomlabs.gradle

import org.gradle.api.Plugin
import org.gradle.api.Project

class IrlInfrastructurePlugin : Plugin<Project> {
    override fun apply(project: Project) {
        // Phase 1: stub
    }
}
```

`src/main/kotlin/com/infiniteroomlabs/gradle/IrlSettingsPlugin.kt`:

```kotlin
package com.infiniteroomlabs.gradle

import org.gradle.api.Plugin
import org.gradle.api.initialization.Settings

class IrlSettingsPlugin : Plugin<Settings> {
    override fun apply(settings: Settings) {
        // Phase 1: stub
    }
}
```

**Step 4: Write first test -- plugin can be applied**

`src/test/kotlin/com/infiniteroomlabs/gradle/IrlInfrastructurePluginTest.kt`:

```kotlin
package com.infiniteroomlabs.gradle

import org.gradle.testfixtures.ProjectBuilder
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.Assertions.assertNotNull

class IrlInfrastructurePluginTest {

    @Test
    fun `plugin can be applied to a project`() {
        val project = ProjectBuilder.builder().build()
        project.plugins.apply("com.infiniteroomlabs.infrastructure")
        assertNotNull(project.plugins.findPlugin(IrlInfrastructurePlugin::class.java))
    }
}
```

**Step 5: Run test to verify it passes**

```bash
./gradlew test
```

Expected: PASS -- plugin applies without error.

**Step 6: Add .gitignore and commit**

Create `.gitignore`:

```
.gradle/
build/
.idea/
*.iml
local.properties
```

```bash
git add -A
git commit -m "feat: scaffold Gradle plugin project with stub plugins"
```

---

## Task 2: Settings Plugin -- Infrastructure DSL for Subproject Registration

**Files:**
- Create: `src/main/kotlin/com/infiniteroomlabs/gradle/dsl/InfrastructureSettingsExtension.kt`
- Create: `src/main/kotlin/com/infiniteroomlabs/gradle/dsl/EnvironmentSpec.kt`
- Create: `src/main/kotlin/com/infiniteroomlabs/gradle/dsl/ProviderSpec.kt`
- Modify: `src/main/kotlin/com/infiniteroomlabs/gradle/IrlSettingsPlugin.kt`
- Test: `src/test/kotlin/com/infiniteroomlabs/gradle/IrlSettingsPluginTest.kt`

**Step 1: Write the failing test**

`src/test/kotlin/com/infiniteroomlabs/gradle/IrlSettingsPluginTest.kt`:

```kotlin
package com.infiniteroomlabs.gradle

import org.gradle.testfixtures.ProjectBuilder
import org.gradle.testkit.runner.GradleRunner
import org.gradle.testkit.runner.TaskOutcome
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import java.io.File
import org.junit.jupiter.api.Assertions.*

class IrlSettingsPluginTest {

    @TempDir
    lateinit var testProjectDir: File

    private fun writeFile(path: String, content: String) {
        val file = File(testProjectDir, path)
        file.parentFile.mkdirs()
        file.writeText(content.trimIndent())
    }

    @Test
    fun `settings plugin registers subprojects from infrastructure DSL`() {
        writeFile("settings.gradle.kts", """
            plugins {
                id("com.infiniteroomlabs.infrastructure.settings")
            }

            infrastructure {
                environment("dev") {
                    provider("cloudflare") {
                        resourceGroup("zones")
                    }
                    provider("porkbun") {
                        resourceGroup("nameservers")
                    }
                }
            }
        """)

        writeFile("build.gradle.kts", "")

        // Create subproject dirs (Gradle requires them to exist)
        File(testProjectDir, "dev/cloudflare/zones").mkdirs()
        File(testProjectDir, "dev/porkbun/nameservers").mkdirs()
        writeFile("dev/cloudflare/zones/build.gradle.kts", "")
        writeFile("dev/porkbun/nameservers/build.gradle.kts", "")

        val result = GradleRunner.create()
            .withProjectDir(testProjectDir)
            .withPluginClasspath()
            .withArguments("projects")
            .build()

        val output = result.output
        assertTrue(output.contains(":dev:cloudflare:zones"), "Expected :dev:cloudflare:zones subproject")
        assertTrue(output.contains(":dev:porkbun:nameservers"), "Expected :dev:porkbun:nameservers subproject")
    }

    @Test
    fun `settings plugin registers multiple environments`() {
        writeFile("settings.gradle.kts", """
            plugins {
                id("com.infiniteroomlabs.infrastructure.settings")
            }

            infrastructure {
                environment("global") {
                    provider("tfc") {
                        resourceGroup("workspaces")
                    }
                }
                environment("dev") {
                    provider("cloudflare") {
                        resourceGroup("zones")
                    }
                }
                environment("prod") {
                    provider("cloudflare") {
                        resourceGroup("zones")
                    }
                }
            }
        """)

        writeFile("build.gradle.kts", "")
        listOf(
            "global/tfc/workspaces",
            "dev/cloudflare/zones",
            "prod/cloudflare/zones"
        ).forEach {
            File(testProjectDir, it).mkdirs()
            writeFile("$it/build.gradle.kts", "")
        }

        val result = GradleRunner.create()
            .withProjectDir(testProjectDir)
            .withPluginClasspath()
            .withArguments("projects")
            .build()

        val output = result.output
        assertTrue(output.contains(":global:tfc:workspaces"))
        assertTrue(output.contains(":dev:cloudflare:zones"))
        assertTrue(output.contains(":prod:cloudflare:zones"))
    }
}
```

**Step 2: Run test to verify it fails**

```bash
./gradlew test
```

Expected: FAIL -- `infrastructure` extension not found.

**Step 3: Implement the DSL and settings plugin**

`src/main/kotlin/com/infiniteroomlabs/gradle/dsl/InfrastructureSettingsExtension.kt`:

```kotlin
package com.infiniteroomlabs.gradle.dsl

import org.gradle.api.model.ObjectFactory
import javax.inject.Inject

abstract class InfrastructureSettingsExtension @Inject constructor(
    private val objects: ObjectFactory
) {
    internal val environments = mutableListOf<EnvironmentSpec>()

    fun environment(name: String, configure: EnvironmentSpec.() -> Unit) {
        val spec = EnvironmentSpec(name)
        spec.configure()
        environments.add(spec)
    }
}
```

`src/main/kotlin/com/infiniteroomlabs/gradle/dsl/EnvironmentSpec.kt`:

```kotlin
package com.infiniteroomlabs.gradle.dsl

class EnvironmentSpec(val name: String) {
    internal val providers = mutableListOf<ProviderSpec>()

    fun provider(name: String, configure: ProviderSpec.() -> Unit) {
        val spec = ProviderSpec(name)
        spec.configure()
        providers.add(spec)
    }
}
```

`src/main/kotlin/com/infiniteroomlabs/gradle/dsl/ProviderSpec.kt`:

```kotlin
package com.infiniteroomlabs.gradle.dsl

class ProviderSpec(val name: String) {
    internal val resourceGroups = mutableListOf<String>()

    fun resourceGroup(name: String) {
        resourceGroups.add(name)
    }
}
```

Update `IrlSettingsPlugin.kt`:

```kotlin
package com.infiniteroomlabs.gradle

import com.infiniteroomlabs.gradle.dsl.InfrastructureSettingsExtension
import org.gradle.api.Plugin
import org.gradle.api.initialization.Settings

class IrlSettingsPlugin : Plugin<Settings> {
    override fun apply(settings: Settings) {
        val extension = settings.extensions.create(
            "infrastructure",
            InfrastructureSettingsExtension::class.java
        )

        settings.gradle.settingsEvaluated {
            registerSubprojects(settings, extension)
        }
    }

    private fun registerSubprojects(settings: Settings, extension: InfrastructureSettingsExtension) {
        for (env in extension.environments) {
            for (provider in env.providers) {
                for (rg in provider.resourceGroups) {
                    val path = ":${env.name}:${provider.name}:$rg"
                    settings.include(path)
                    // Set the physical directory relative to project root
                    val project = settings.project(path)
                    project.projectDir = settings.rootDir.resolve("${env.name}/${provider.name}/$rg")
                }
            }
        }
    }
}
```

**Step 4: Run tests to verify they pass**

```bash
./gradlew test
```

Expected: PASS -- both tests green.

**Step 5: Commit**

```bash
git add -A
git commit -m "feat: add settings plugin with infrastructure DSL for subproject registration"
```

---

## Task 3: Project Plugin -- Shared Infrastructure Configuration

**Files:**
- Create: `src/main/kotlin/com/infiniteroomlabs/gradle/dsl/InfrastructureExtension.kt`
- Create: `src/main/kotlin/com/infiniteroomlabs/gradle/dsl/StateBackendSpec.kt`
- Create: `src/main/kotlin/com/infiniteroomlabs/gradle/dsl/TerraformCloudSpec.kt`
- Create: `src/main/kotlin/com/infiniteroomlabs/gradle/dsl/ProviderVersionSpec.kt`
- Modify: `src/main/kotlin/com/infiniteroomlabs/gradle/IrlInfrastructurePlugin.kt`
- Test: `src/test/kotlin/com/infiniteroomlabs/gradle/InfrastructureExtensionTest.kt`

**Step 1: Write the failing test**

`src/test/kotlin/com/infiniteroomlabs/gradle/InfrastructureExtensionTest.kt`:

```kotlin
package com.infiniteroomlabs.gradle

import org.gradle.testfixtures.ProjectBuilder
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.Assertions.*
import com.infiniteroomlabs.gradle.dsl.InfrastructureExtension

class InfrastructureExtensionTest {

    @Test
    fun `plugin registers infrastructure extension`() {
        val project = ProjectBuilder.builder().build()
        project.plugins.apply("com.infiniteroomlabs.infrastructure")

        val ext = project.extensions.findByType(InfrastructureExtension::class.java)
        assertNotNull(ext)
    }

    @Test
    fun `extension accepts state backend configuration`() {
        val project = ProjectBuilder.builder().build()
        project.plugins.apply("com.infiniteroomlabs.infrastructure")

        val ext = project.extensions.getByType(InfrastructureExtension::class.java)
        ext.stateBackend {
            terraformCloud {
                organization = "infinite-room-labs"
            }
        }

        assertEquals("infinite-room-labs", ext.stateBackend.terraformCloud.organization)
    }

    @Test
    fun `extension accepts provider version constraints`() {
        val project = ProjectBuilder.builder().build()
        project.plugins.apply("com.infiniteroomlabs.infrastructure")

        val ext = project.extensions.getByType(InfrastructureExtension::class.java)
        ext.providers {
            provider("cloudflare") { version = "~> 5.17" }
            provider("porkbun") { version = "~> 0.2" }
        }

        assertEquals("~> 5.17", ext.providers.get("cloudflare")?.version)
        assertEquals("~> 0.2", ext.providers.get("porkbun")?.version)
    }

    @Test
    fun `extension supports local state flag`() {
        val project = ProjectBuilder.builder().build()
        project.plugins.apply("com.infiniteroomlabs.infrastructure")

        val ext = project.extensions.getByType(InfrastructureExtension::class.java)
        ext.localState = true

        assertTrue(ext.localState)
    }
}
```

**Step 2: Run test to verify it fails**

```bash
./gradlew test
```

Expected: FAIL -- `InfrastructureExtension` not found.

**Step 3: Implement the extension and DSL types**

`src/main/kotlin/com/infiniteroomlabs/gradle/dsl/StateBackendSpec.kt`:

```kotlin
package com.infiniteroomlabs.gradle.dsl

class StateBackendSpec {
    val terraformCloud = TerraformCloudSpec()

    fun terraformCloud(configure: TerraformCloudSpec.() -> Unit) {
        terraformCloud.configure()
    }
}

class TerraformCloudSpec {
    var organization: String = ""
}
```

`src/main/kotlin/com/infiniteroomlabs/gradle/dsl/ProviderVersionSpec.kt`:

```kotlin
package com.infiniteroomlabs.gradle.dsl

class ProviderVersionSpec(val name: String) {
    var version: String = ""
}

class ProvidersSpec {
    private val providers = mutableMapOf<String, ProviderVersionSpec>()

    fun provider(name: String, configure: ProviderVersionSpec.() -> Unit) {
        val spec = ProviderVersionSpec(name)
        spec.configure()
        providers[name] = spec
    }

    fun get(name: String): ProviderVersionSpec? = providers[name]

    fun all(): Map<String, ProviderVersionSpec> = providers.toMap()
}
```

`src/main/kotlin/com/infiniteroomlabs/gradle/dsl/InfrastructureExtension.kt`:

```kotlin
package com.infiniteroomlabs.gradle.dsl

import org.gradle.api.model.ObjectFactory
import javax.inject.Inject

abstract class InfrastructureExtension @Inject constructor(
    private val objects: ObjectFactory
) {
    val stateBackend = StateBackendSpec()
    val providers = ProvidersSpec()
    var localState: Boolean = false

    // Subproject-level config
    var module: String = ""
    internal val dependencies = mutableListOf<String>()
    internal val inputSources = mutableListOf<InputSource>()

    fun stateBackend(configure: StateBackendSpec.() -> Unit) {
        stateBackend.configure()
    }

    fun providers(configure: ProvidersSpec.() -> Unit) {
        providers.configure()
    }

    fun dependsOn(projectPath: String) {
        dependencies.add(projectPath)
    }
}

sealed interface InputSource {
    data class FromDependencyOutput(val projectPath: String, val outputName: String) : InputSource
    data class FromProperty(val key: String, val value: String) : InputSource
}
```

Update `IrlInfrastructurePlugin.kt`:

```kotlin
package com.infiniteroomlabs.gradle

import com.infiniteroomlabs.gradle.dsl.InfrastructureExtension
import org.gradle.api.Plugin
import org.gradle.api.Project

class IrlInfrastructurePlugin : Plugin<Project> {
    override fun apply(project: Project) {
        project.extensions.create(
            "infrastructure",
            InfrastructureExtension::class.java
        )
    }
}
```

**Step 4: Run tests to verify they pass**

```bash
./gradlew test
```

Expected: PASS.

**Step 5: Commit**

```bash
git add -A
git commit -m "feat: add project-level infrastructure extension with state backend, providers, and local state"
```

---

## Task 4: Terragrunt Shell-Out Engine

**Files:**
- Create: `src/main/kotlin/com/infiniteroomlabs/gradle/engine/TerragruntExecutor.kt`
- Create: `src/main/kotlin/com/infiniteroomlabs/gradle/engine/CommandResult.kt`
- Test: `src/test/kotlin/com/infiniteroomlabs/gradle/engine/TerragruntExecutorTest.kt`

**Step 1: Write the failing test**

`src/test/kotlin/com/infiniteroomlabs/gradle/engine/TerragruntExecutorTest.kt`:

```kotlin
package com.infiniteroomlabs.gradle.engine

import org.junit.jupiter.api.Test
import org.junit.jupiter.api.Assertions.*
import org.junit.jupiter.api.io.TempDir
import java.io.File

class TerragruntExecutorTest {

    @TempDir
    lateinit var workDir: File

    @Test
    fun `buildCommand constructs correct terragrunt command`() {
        val executor = TerragruntExecutor(workDir)
        val cmd = executor.buildCommand("plan")
        assertEquals(listOf("terragrunt", "plan"), cmd)
    }

    @Test
    fun `buildCommand includes extra args`() {
        val executor = TerragruntExecutor(workDir)
        val cmd = executor.buildCommand("apply", listOf("-auto-approve"))
        assertEquals(listOf("terragrunt", "apply", "-auto-approve"), cmd)
    }

    @Test
    fun `buildCommand constructs init command`() {
        val executor = TerragruntExecutor(workDir)
        val cmd = executor.buildCommand("init")
        assertEquals(listOf("terragrunt", "init"), cmd)
    }

    @Test
    fun `buildCommand constructs output command with json flag`() {
        val executor = TerragruntExecutor(workDir)
        val cmd = executor.buildCommand("output", listOf("-json"))
        assertEquals(listOf("terragrunt", "output", "-json"), cmd)
    }

    @Test
    fun `execute runs command in working directory`() {
        // Create a simple script to verify working directory
        val script = File(workDir, "test-script.sh")
        script.writeText("#!/bin/bash\npwd")
        script.setExecutable(true)

        val executor = TerragruntExecutor(workDir)
        val result = executor.executeRaw(listOf(script.absolutePath))

        assertEquals(0, result.exitCode)
        assertTrue(result.stdout.trim().endsWith(workDir.name))
    }

    @Test
    fun `execute captures stderr on failure`() {
        val executor = TerragruntExecutor(workDir)
        val result = executor.executeRaw(listOf("bash", "-c", "echo 'error msg' >&2; exit 1"))

        assertEquals(1, result.exitCode)
        assertTrue(result.stderr.contains("error msg"))
    }
}
```

**Step 2: Run test to verify it fails**

```bash
./gradlew test
```

Expected: FAIL -- `TerragruntExecutor` not found.

**Step 3: Implement the engine**

`src/main/kotlin/com/infiniteroomlabs/gradle/engine/CommandResult.kt`:

```kotlin
package com.infiniteroomlabs.gradle.engine

data class CommandResult(
    val exitCode: Int,
    val stdout: String,
    val stderr: String
) {
    val success: Boolean get() = exitCode == 0
}
```

`src/main/kotlin/com/infiniteroomlabs/gradle/engine/TerragruntExecutor.kt`:

```kotlin
package com.infiniteroomlabs.gradle.engine

import java.io.File

class TerragruntExecutor(
    private val workingDir: File,
    private val terragruntBinary: String = "terragrunt"
) {
    fun buildCommand(action: String, extraArgs: List<String> = emptyList()): List<String> {
        return listOf(terragruntBinary, action) + extraArgs
    }

    fun execute(action: String, extraArgs: List<String> = emptyList(), env: Map<String, String> = emptyMap()): CommandResult {
        val command = buildCommand(action, extraArgs)
        return executeRaw(command, env)
    }

    fun executeRaw(command: List<String>, env: Map<String, String> = emptyMap()): CommandResult {
        val process = ProcessBuilder(command)
            .directory(workingDir)
            .apply {
                environment().putAll(env)
            }
            .start()

        val stdout = process.inputStream.bufferedReader().readText()
        val stderr = process.errorStream.bufferedReader().readText()
        val exitCode = process.waitFor()

        return CommandResult(exitCode, stdout, stderr)
    }
}
```

**Step 4: Run tests to verify they pass**

```bash
./gradlew test
```

Expected: PASS.

**Step 5: Commit**

```bash
git add -A
git commit -m "feat: add TerragruntExecutor with shell-out command building and execution"
```

---

## Task 5: Terragrunt Task Types

**Files:**
- Create: `src/main/kotlin/com/infiniteroomlabs/gradle/tasks/TerragruntTask.kt`
- Create: `src/main/kotlin/com/infiniteroomlabs/gradle/tasks/TerragruntInit.kt`
- Create: `src/main/kotlin/com/infiniteroomlabs/gradle/tasks/TerragruntValidate.kt`
- Create: `src/main/kotlin/com/infiniteroomlabs/gradle/tasks/TerragruntPlan.kt`
- Create: `src/main/kotlin/com/infiniteroomlabs/gradle/tasks/TerragruntApply.kt`
- Create: `src/main/kotlin/com/infiniteroomlabs/gradle/tasks/TerragruntDestroy.kt`
- Create: `src/main/kotlin/com/infiniteroomlabs/gradle/tasks/TerragruntOutput.kt`
- Test: `src/test/kotlin/com/infiniteroomlabs/gradle/tasks/TerragruntTaskTest.kt`

**Step 1: Write the failing test**

`src/test/kotlin/com/infiniteroomlabs/gradle/tasks/TerragruntTaskTest.kt`:

```kotlin
package com.infiniteroomlabs.gradle.tasks

import org.gradle.testkit.runner.GradleRunner
import org.gradle.testkit.runner.TaskOutcome
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import org.junit.jupiter.api.Assertions.*
import java.io.File

class TerragruntTaskTest {

    @TempDir
    lateinit var testProjectDir: File

    private fun writeFile(path: String, content: String) {
        val file = File(testProjectDir, path)
        file.parentFile.mkdirs()
        file.writeText(content.trimIndent())
    }

    /**
     * Uses a fake terragrunt script that logs which action was called.
     * This avoids needing real Terraform/Terragrunt installed in CI.
     */
    private fun writeFakeTerragrunt() {
        val bin = File(testProjectDir, "bin")
        bin.mkdirs()
        val fake = File(bin, "terragrunt")
        fake.writeText("""
            #!/bin/bash
            echo "TERRAGRUNT_ACTION=$1"
            echo "TERRAGRUNT_WORKDIR=$(pwd)"
            echo "TERRAGRUNT_ARGS=$@"
        """.trimIndent())
        fake.setExecutable(true)
    }

    @Test
    fun `plan task executes terragrunt plan in subproject directory`() {
        writeFakeTerragrunt()

        writeFile("settings.gradle.kts", """
            plugins {
                id("com.infiniteroomlabs.infrastructure.settings")
            }
            infrastructure {
                environment("dev") {
                    provider("cloudflare") {
                        resourceGroup("zones")
                    }
                }
            }
        """)

        writeFile("build.gradle.kts", """
            plugins {
                id("com.infiniteroomlabs.infrastructure")
            }
            infrastructure {
                terragruntBinary = "${'$'}{rootDir}/bin/terragrunt"
            }
        """)

        File(testProjectDir, "dev/cloudflare/zones").mkdirs()
        writeFile("dev/cloudflare/zones/build.gradle.kts", """
            plugins {
                id("com.infiniteroomlabs.infrastructure")
            }
        """)

        val result = GradleRunner.create()
            .withProjectDir(testProjectDir)
            .withPluginClasspath()
            .withArguments(":dev:cloudflare:zones:plan", "--stacktrace")
            .build()

        assertEquals(TaskOutcome.SUCCESS, result.task(":dev:cloudflare:zones:plan")?.outcome)
        assertTrue(result.output.contains("TERRAGRUNT_ACTION=plan"))
        assertTrue(result.output.contains("dev/cloudflare/zones"))
    }

    @Test
    fun `apply task passes auto-approve flag`() {
        writeFakeTerragrunt()

        writeFile("settings.gradle.kts", """
            plugins {
                id("com.infiniteroomlabs.infrastructure.settings")
            }
            infrastructure {
                environment("dev") {
                    provider("cloudflare") {
                        resourceGroup("zones")
                    }
                }
            }
        """)

        writeFile("build.gradle.kts", """
            plugins {
                id("com.infiniteroomlabs.infrastructure")
            }
            infrastructure {
                terragruntBinary = "${'$'}{rootDir}/bin/terragrunt"
            }
        """)

        File(testProjectDir, "dev/cloudflare/zones").mkdirs()
        writeFile("dev/cloudflare/zones/build.gradle.kts", """
            plugins {
                id("com.infiniteroomlabs.infrastructure")
            }
        """)

        val result = GradleRunner.create()
            .withProjectDir(testProjectDir)
            .withPluginClasspath()
            .withArguments(":dev:cloudflare:zones:apply", "--stacktrace")
            .build()

        assertEquals(TaskOutcome.SUCCESS, result.task(":dev:cloudflare:zones:apply")?.outcome)
        assertTrue(result.output.contains("TERRAGRUNT_ACTION=apply"))
        assertTrue(result.output.contains("-auto-approve"))
    }

    @Test
    fun `init task runs before plan`() {
        writeFakeTerragrunt()

        writeFile("settings.gradle.kts", """
            plugins {
                id("com.infiniteroomlabs.infrastructure.settings")
            }
            infrastructure {
                environment("dev") {
                    provider("cloudflare") {
                        resourceGroup("zones")
                    }
                }
            }
        """)

        writeFile("build.gradle.kts", """
            plugins {
                id("com.infiniteroomlabs.infrastructure")
            }
            infrastructure {
                terragruntBinary = "${'$'}{rootDir}/bin/terragrunt"
            }
        """)

        File(testProjectDir, "dev/cloudflare/zones").mkdirs()
        writeFile("dev/cloudflare/zones/build.gradle.kts", """
            plugins {
                id("com.infiniteroomlabs.infrastructure")
            }
        """)

        val result = GradleRunner.create()
            .withProjectDir(testProjectDir)
            .withPluginClasspath()
            .withArguments(":dev:cloudflare:zones:plan", "--stacktrace")
            .build()

        assertNotNull(result.task(":dev:cloudflare:zones:init"))
        val initOrder = result.output.indexOf("TERRAGRUNT_ACTION=init")
        val planOrder = result.output.indexOf("TERRAGRUNT_ACTION=plan")
        assertTrue(initOrder < planOrder, "init should run before plan")
    }

    @Test
    fun `output task produces JSON`() {
        writeFakeTerragrunt()

        writeFile("settings.gradle.kts", """
            plugins {
                id("com.infiniteroomlabs.infrastructure.settings")
            }
            infrastructure {
                environment("dev") {
                    provider("cloudflare") {
                        resourceGroup("zones")
                    }
                }
            }
        """)

        writeFile("build.gradle.kts", """
            plugins {
                id("com.infiniteroomlabs.infrastructure")
            }
            infrastructure {
                terragruntBinary = "${'$'}{rootDir}/bin/terragrunt"
            }
        """)

        File(testProjectDir, "dev/cloudflare/zones").mkdirs()
        writeFile("dev/cloudflare/zones/build.gradle.kts", """
            plugins {
                id("com.infiniteroomlabs.infrastructure")
            }
        """)

        val result = GradleRunner.create()
            .withProjectDir(testProjectDir)
            .withPluginClasspath()
            .withArguments(":dev:cloudflare:zones:output", "--stacktrace")
            .build()

        assertEquals(TaskOutcome.SUCCESS, result.task(":dev:cloudflare:zones:output")?.outcome)
        assertTrue(result.output.contains("TERRAGRUNT_ACTION=output"))
        assertTrue(result.output.contains("-json"))
    }
}
```

**Step 2: Run test to verify it fails**

```bash
./gradlew test
```

Expected: FAIL -- tasks not registered.

**Step 3: Implement task types**

`src/main/kotlin/com/infiniteroomlabs/gradle/tasks/TerragruntTask.kt`:

```kotlin
package com.infiniteroomlabs.gradle.tasks

import com.infiniteroomlabs.gradle.engine.TerragruntExecutor
import org.gradle.api.DefaultTask
import org.gradle.api.GradleException
import org.gradle.api.provider.Property
import org.gradle.api.tasks.Input
import org.gradle.api.tasks.Internal
import org.gradle.api.tasks.TaskAction

abstract class TerragruntTask : DefaultTask() {

    @get:Input
    abstract val action: Property<String>

    @get:Input
    abstract val terragruntBinary: Property<String>

    @get:Internal
    val extraArgs = mutableListOf<String>()

    init {
        terragruntBinary.convention("terragrunt")
    }

    @TaskAction
    fun execute() {
        val executor = TerragruntExecutor(
            workingDir = project.projectDir,
            terragruntBinary = terragruntBinary.get()
        )
        val result = executor.execute(action.get(), extraArgs)

        if (result.stdout.isNotBlank()) println(result.stdout)
        if (result.stderr.isNotBlank()) System.err.println(result.stderr)

        if (!result.success) {
            throw GradleException("terragrunt ${action.get()} failed with exit code ${result.exitCode}")
        }
    }
}
```

Individual task types -- each in its own file:

`src/main/kotlin/com/infiniteroomlabs/gradle/tasks/TerragruntInit.kt`:

```kotlin
package com.infiniteroomlabs.gradle.tasks

abstract class TerragruntInit : TerragruntTask() {
    init {
        action.set("init")
        description = "Run terragrunt init"
        group = "infrastructure"
    }
}
```

`src/main/kotlin/com/infiniteroomlabs/gradle/tasks/TerragruntValidate.kt`:

```kotlin
package com.infiniteroomlabs.gradle.tasks

abstract class TerragruntValidate : TerragruntTask() {
    init {
        action.set("validate")
        description = "Run terragrunt validate"
        group = "infrastructure"
    }
}
```

`src/main/kotlin/com/infiniteroomlabs/gradle/tasks/TerragruntPlan.kt`:

```kotlin
package com.infiniteroomlabs.gradle.tasks

abstract class TerragruntPlan : TerragruntTask() {
    init {
        action.set("plan")
        description = "Run terragrunt plan"
        group = "infrastructure"
    }
}
```

`src/main/kotlin/com/infiniteroomlabs/gradle/tasks/TerragruntApply.kt`:

```kotlin
package com.infiniteroomlabs.gradle.tasks

abstract class TerragruntApply : TerragruntTask() {
    init {
        action.set("apply")
        extraArgs.add("-auto-approve")
        description = "Run terragrunt apply"
        group = "infrastructure"
    }
}
```

`src/main/kotlin/com/infiniteroomlabs/gradle/tasks/TerragruntDestroy.kt`:

```kotlin
package com.infiniteroomlabs.gradle.tasks

abstract class TerragruntDestroy : TerragruntTask() {
    init {
        action.set("destroy")
        description = "Run terragrunt destroy (requires -Pdestroy.confirm=true)"
        group = "infrastructure"
    }
}
```

`src/main/kotlin/com/infiniteroomlabs/gradle/tasks/TerragruntOutput.kt`:

```kotlin
package com.infiniteroomlabs.gradle.tasks

abstract class TerragruntOutput : TerragruntTask() {
    init {
        action.set("output")
        extraArgs.add("-json")
        description = "Run terragrunt output -json"
        group = "infrastructure"
    }
}
```

**Step 4: Wire task registration into the plugin**

Update `IrlInfrastructurePlugin.kt`:

```kotlin
package com.infiniteroomlabs.gradle

import com.infiniteroomlabs.gradle.dsl.InfrastructureExtension
import com.infiniteroomlabs.gradle.tasks.*
import org.gradle.api.Plugin
import org.gradle.api.Project

class IrlInfrastructurePlugin : Plugin<Project> {
    override fun apply(project: Project) {
        val extension = project.extensions.create(
            "infrastructure",
            InfrastructureExtension::class.java
        )

        project.afterEvaluate {
            // Only register tasks on subprojects (leaf nodes), not the root
            if (project != project.rootProject) {
                registerTasks(project, extension)
            }
        }
    }

    private fun registerTasks(project: Project, extension: InfrastructureExtension) {
        val binary = resolveRootBinary(project)

        val init = project.tasks.register("init", TerragruntInit::class.java) {
            it.terragruntBinary.set(binary)
        }

        val validate = project.tasks.register("validate", TerragruntValidate::class.java) {
            it.terragruntBinary.set(binary)
            it.dependsOn(init)
        }

        val plan = project.tasks.register("plan", TerragruntPlan::class.java) {
            it.terragruntBinary.set(binary)
            it.dependsOn(init)
        }

        project.tasks.register("apply", TerragruntApply::class.java) {
            it.terragruntBinary.set(binary)
            it.dependsOn(init)
        }

        project.tasks.register("destroy", TerragruntDestroy::class.java) {
            it.terragruntBinary.set(binary)
            it.dependsOn(init)
        }

        project.tasks.register("output", TerragruntOutput::class.java) {
            it.terragruntBinary.set(binary)
            it.dependsOn(init)
        }
    }

    private fun resolveRootBinary(project: Project): String {
        val rootExt = project.rootProject.extensions.findByType(InfrastructureExtension::class.java)
        return rootExt?.terragruntBinary ?: "terragrunt"
    }
}
```

Add `terragruntBinary` to `InfrastructureExtension.kt`:

```kotlin
// Add to InfrastructureExtension class:
var terragruntBinary: String = "terragrunt"
```

**Step 5: Run tests to verify they pass**

```bash
./gradlew test
```

Expected: PASS -- all task tests green.

**Step 6: Commit**

```bash
git add -A
git commit -m "feat: add Terragrunt task types with shell-out execution"
```

---

## Task 6: DAG Dependency Wiring Between Subprojects

**Files:**
- Modify: `src/main/kotlin/com/infiniteroomlabs/gradle/IrlInfrastructurePlugin.kt`
- Test: `src/test/kotlin/com/infiniteroomlabs/gradle/DependencyWiringTest.kt`

**Step 1: Write the failing test**

`src/test/kotlin/com/infiniteroomlabs/gradle/DependencyWiringTest.kt`:

```kotlin
package com.infiniteroomlabs.gradle

import org.gradle.testkit.runner.GradleRunner
import org.gradle.testkit.runner.TaskOutcome
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import org.junit.jupiter.api.Assertions.*
import java.io.File

class DependencyWiringTest {

    @TempDir
    lateinit var testProjectDir: File

    private fun writeFile(path: String, content: String) {
        val file = File(testProjectDir, path)
        file.parentFile.mkdirs()
        file.writeText(content.trimIndent())
    }

    private fun writeFakeTerragrunt() {
        val bin = File(testProjectDir, "bin")
        bin.mkdirs()
        val fake = File(bin, "terragrunt")
        fake.writeText("""
            #!/bin/bash
            echo "EXEC:$(basename $(pwd)):$1"
        """.trimIndent())
        fake.setExecutable(true)
    }

    @Test
    fun `apply on downstream subproject triggers upstream dependencies`() {
        writeFakeTerragrunt()

        writeFile("settings.gradle.kts", """
            plugins {
                id("com.infiniteroomlabs.infrastructure.settings")
            }
            infrastructure {
                environment("global") {
                    provider("cloudflare") {
                        resourceGroup("tokens")
                    }
                }
                environment("dev") {
                    provider("cloudflare") {
                        resourceGroup("zones")
                    }
                    provider("porkbun") {
                        resourceGroup("nameservers")
                    }
                }
            }
        """)

        writeFile("build.gradle.kts", """
            plugins {
                id("com.infiniteroomlabs.infrastructure")
            }
            infrastructure {
                terragruntBinary = "${'$'}{rootDir}/bin/terragrunt"
            }
        """)

        // Bootstrap: no deps
        File(testProjectDir, "global/cloudflare/tokens").mkdirs()
        writeFile("global/cloudflare/tokens/build.gradle.kts", """
            plugins {
                id("com.infiniteroomlabs.infrastructure")
            }
        """)

        // Zones depend on tokens
        File(testProjectDir, "dev/cloudflare/zones").mkdirs()
        writeFile("dev/cloudflare/zones/build.gradle.kts", """
            plugins {
                id("com.infiniteroomlabs.infrastructure")
            }
            infrastructure {
                dependsOn(":global:cloudflare:tokens")
            }
        """)

        // Nameservers depend on zones
        File(testProjectDir, "dev/porkbun/nameservers").mkdirs()
        writeFile("dev/porkbun/nameservers/build.gradle.kts", """
            plugins {
                id("com.infiniteroomlabs.infrastructure")
            }
            infrastructure {
                dependsOn(":dev:cloudflare:zones")
            }
        """)

        val result = GradleRunner.create()
            .withProjectDir(testProjectDir)
            .withPluginClasspath()
            .withArguments(":dev:porkbun:nameservers:apply", "--stacktrace")
            .build()

        val output = result.output

        // All three should have run
        assertNotNull(result.task(":global:cloudflare:tokens:apply"))
        assertNotNull(result.task(":dev:cloudflare:zones:apply"))
        assertNotNull(result.task(":dev:porkbun:nameservers:apply"))

        // Order: tokens before zones before nameservers
        val tokensIdx = output.indexOf("EXEC:tokens:apply")
        val zonesIdx = output.indexOf("EXEC:zones:apply")
        val nsIdx = output.indexOf("EXEC:nameservers:apply")

        assertTrue(tokensIdx < zonesIdx, "tokens:apply should run before zones:apply")
        assertTrue(zonesIdx < nsIdx, "zones:apply should run before nameservers:apply")
    }

    @Test
    fun `plan on downstream does NOT trigger upstream apply`() {
        writeFakeTerragrunt()

        writeFile("settings.gradle.kts", """
            plugins {
                id("com.infiniteroomlabs.infrastructure.settings")
            }
            infrastructure {
                environment("dev") {
                    provider("cloudflare") {
                        resourceGroup("zones")
                    }
                    provider("porkbun") {
                        resourceGroup("nameservers")
                    }
                }
            }
        """)

        writeFile("build.gradle.kts", """
            plugins {
                id("com.infiniteroomlabs.infrastructure")
            }
            infrastructure {
                terragruntBinary = "${'$'}{rootDir}/bin/terragrunt"
            }
        """)

        File(testProjectDir, "dev/cloudflare/zones").mkdirs()
        writeFile("dev/cloudflare/zones/build.gradle.kts", """
            plugins {
                id("com.infiniteroomlabs.infrastructure")
            }
        """)

        File(testProjectDir, "dev/porkbun/nameservers").mkdirs()
        writeFile("dev/porkbun/nameservers/build.gradle.kts", """
            plugins {
                id("com.infiniteroomlabs.infrastructure")
            }
            infrastructure {
                dependsOn(":dev:cloudflare:zones")
            }
        """)

        val result = GradleRunner.create()
            .withProjectDir(testProjectDir)
            .withPluginClasspath()
            .withArguments(":dev:porkbun:nameservers:plan", "--stacktrace")
            .build()

        // plan should trigger upstream plan (not apply)
        assertNotNull(result.task(":dev:cloudflare:zones:plan"))
        assertNull(result.task(":dev:cloudflare:zones:apply"))
    }
}
```

**Step 2: Run test to verify it fails**

```bash
./gradlew test
```

Expected: FAIL -- dependencies not wired.

**Step 3: Update plugin to wire dependencies**

Update `IrlInfrastructurePlugin.kt` -- add dependency wiring in `afterEvaluate`:

```kotlin
private fun registerTasks(project: Project, extension: InfrastructureExtension) {
    val binary = resolveRootBinary(project)

    val init = project.tasks.register("init", TerragruntInit::class.java) {
        it.terragruntBinary.set(binary)
    }

    project.tasks.register("validate", TerragruntValidate::class.java) {
        it.terragruntBinary.set(binary)
        it.dependsOn(init)
    }

    val plan = project.tasks.register("plan", TerragruntPlan::class.java) {
        it.terragruntBinary.set(binary)
        it.dependsOn(init)
    }

    val apply = project.tasks.register("apply", TerragruntApply::class.java) {
        it.terragruntBinary.set(binary)
        it.dependsOn(init)
    }

    project.tasks.register("destroy", TerragruntDestroy::class.java) {
        it.terragruntBinary.set(binary)
        it.dependsOn(init)
    }

    project.tasks.register("output", TerragruntOutput::class.java) {
        it.terragruntBinary.set(binary)
        it.dependsOn(init)
    }

    // Wire cross-subproject dependencies
    // apply depends on upstream apply; plan depends on upstream plan
    for (depPath in extension.dependencies) {
        val depProject = project.project(depPath)

        apply.configure { it.dependsOn(depProject.tasks.named("apply")) }
        plan.configure { it.dependsOn(depProject.tasks.named("plan")) }
    }
}
```

**Step 4: Run tests to verify they pass**

```bash
./gradlew test
```

Expected: PASS.

**Step 5: Commit**

```bash
git add -A
git commit -m "feat: wire DAG dependencies between subprojects for apply and plan chains"
```

---

## Task 7: Destroy Safety Gate

**Files:**
- Modify: `src/main/kotlin/com/infiniteroomlabs/gradle/tasks/TerragruntDestroy.kt`
- Test: `src/test/kotlin/com/infiniteroomlabs/gradle/tasks/DestroyGateTest.kt`

**Step 1: Write the failing test**

`src/test/kotlin/com/infiniteroomlabs/gradle/tasks/DestroyGateTest.kt`:

```kotlin
package com.infiniteroomlabs.gradle.tasks

import org.gradle.testkit.runner.GradleRunner
import org.gradle.testkit.runner.UnexpectedBuildFailure
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import org.junit.jupiter.api.Assertions.*
import java.io.File

class DestroyGateTest {

    @TempDir
    lateinit var testProjectDir: File

    private fun writeFile(path: String, content: String) {
        val file = File(testProjectDir, path)
        file.parentFile.mkdirs()
        file.writeText(content.trimIndent())
    }

    private fun writeFakeTerragrunt() {
        val bin = File(testProjectDir, "bin")
        bin.mkdirs()
        val fake = File(bin, "terragrunt")
        fake.writeText("#!/bin/bash\necho \"TERRAGRUNT_ACTION=\$1\"")
        fake.setExecutable(true)
    }

    private fun setupProject() {
        writeFakeTerragrunt()
        writeFile("settings.gradle.kts", """
            plugins {
                id("com.infiniteroomlabs.infrastructure.settings")
            }
            infrastructure {
                environment("dev") {
                    provider("cloudflare") {
                        resourceGroup("zones")
                    }
                }
            }
        """)
        writeFile("build.gradle.kts", """
            plugins {
                id("com.infiniteroomlabs.infrastructure")
            }
            infrastructure {
                terragruntBinary = "${'$'}{rootDir}/bin/terragrunt"
            }
        """)
        File(testProjectDir, "dev/cloudflare/zones").mkdirs()
        writeFile("dev/cloudflare/zones/build.gradle.kts", """
            plugins {
                id("com.infiniteroomlabs.infrastructure")
            }
        """)
    }

    @Test
    fun `destroy fails without confirmation property`() {
        setupProject()

        val result = GradleRunner.create()
            .withProjectDir(testProjectDir)
            .withPluginClasspath()
            .withArguments(":dev:cloudflare:zones:destroy", "--stacktrace")
            .buildAndFail()

        assertTrue(result.output.contains("destroy.confirm"))
    }

    @Test
    fun `destroy succeeds with confirmation property`() {
        setupProject()

        val result = GradleRunner.create()
            .withProjectDir(testProjectDir)
            .withPluginClasspath()
            .withArguments(":dev:cloudflare:zones:destroy", "-Pdestroy.confirm=true", "--stacktrace")
            .build()

        assertTrue(result.output.contains("TERRAGRUNT_ACTION=destroy"))
    }
}
```

**Step 2: Run test to verify it fails**

```bash
./gradlew test
```

Expected: FAIL -- destroy runs without confirmation.

**Step 3: Add safety gate to TerragruntDestroy**

Update `src/main/kotlin/com/infiniteroomlabs/gradle/tasks/TerragruntDestroy.kt`:

```kotlin
package com.infiniteroomlabs.gradle.tasks

import org.gradle.api.GradleException

abstract class TerragruntDestroy : TerragruntTask() {
    init {
        action.set("destroy")
        extraArgs.add("-auto-approve")
        description = "Run terragrunt destroy (requires -Pdestroy.confirm=true)"
        group = "infrastructure"
    }

    override fun execute() {
        val confirmed = project.findProperty("destroy.confirm")?.toString()?.toBoolean() ?: false
        if (!confirmed) {
            throw GradleException(
                "Destroy requires explicit confirmation. Run with -Pdestroy.confirm=true\n" +
                "Target: ${project.path}"
            )
        }
        super.execute()
    }
}
```

Make the base `execute()` in `TerragruntTask` open:

```kotlin
// In TerragruntTask.kt, change:
@TaskAction
open fun execute() {
```

**Step 4: Run tests to verify they pass**

```bash
./gradlew test
```

Expected: PASS.

**Step 5: Commit**

```bash
git add -A
git commit -m "feat: add safety gate requiring explicit confirmation for destroy tasks"
```

---

## Task 8: Proving Ground Integration

This task applies the plugin to `infinite-room-labs-infra` and verifies it works against real Terragrunt configs.

**Files:**
- Create: `~/projects/infinite-room-labs/infinite-room-labs-infra/settings.gradle.kts`
- Create: `~/projects/infinite-room-labs/infinite-room-labs-infra/build.gradle.kts`
- Create: `~/projects/infinite-room-labs/infinite-room-labs-infra/dev/cloudflare/zones/build.gradle.kts`
- Create: (similar for each of the 6 subprojects)

**Step 1: Publish the plugin to local Maven**

Add to `irl-gradle-plugin/build.gradle.kts`:

```kotlin
plugins {
    `java-gradle-plugin`
    `maven-publish`
    alias(libs.plugins.kotlin.jvm)
}

publishing {
    repositories {
        mavenLocal()
    }
}
```

```bash
cd ~/projects/infinite-room-labs/irl-gradle-plugin
./gradlew publishToMavenLocal
```

**Step 2: Create settings.gradle.kts in the infra repo**

`~/projects/infinite-room-labs/infinite-room-labs-infra/settings.gradle.kts`:

```kotlin
pluginManagement {
    repositories {
        mavenLocal()
        gradlePluginPortal()
    }
}

plugins {
    id("com.infiniteroomlabs.infrastructure.settings") version "0.1.0-SNAPSHOT"
}

rootProject.name = "infinite-room-labs-infra"

infrastructure {
    environment("global") {
        provider("tfc") { resourceGroup("workspaces") }
        provider("cloudflare") { resourceGroup("tokens") }
    }
    environment("dev") {
        provider("cloudflare") { resourceGroup("zones") }
        provider("porkbun") { resourceGroup("nameservers") }
    }
    environment("prod") {
        provider("cloudflare") { resourceGroup("zones") }
        provider("porkbun") { resourceGroup("nameservers") }
    }
}
```

**Step 3: Create root build.gradle.kts**

`~/projects/infinite-room-labs/infinite-room-labs-infra/build.gradle.kts`:

```kotlin
plugins {
    id("com.infiniteroomlabs.infrastructure") version "0.1.0-SNAPSHOT"
}

infrastructure {
    stateBackend {
        terraformCloud {
            organization = "infinite-room-labs"
        }
    }
    providers {
        provider("cloudflare") { version = "~> 5.17" }
        provider("porkbun") { version = "~> 0.2" }
    }
}
```

**Step 4: Create subproject build files**

The settings plugin maps subprojects to `{env}/{provider}/{rg}` directories, but our Terragrunt files live in `terraform/environments/{env}/{provider}/{rg}`. We need to configure the settings plugin to support a custom base path, OR create symlinks/build files that point to the right Terragrunt working directory.

The simplest approach for Phase 1: add a `terragruntDir` property to the extension that tells the task where to actually run Terragrunt.

Add to `InfrastructureExtension`:

```kotlin
var terragruntDir: String = ""  // defaults to project.projectDir
```

Update `TerragruntTask` to use it:

```kotlin
@TaskAction
open fun execute() {
    val ext = project.extensions.findByType(InfrastructureExtension::class.java)
    val workDir = if (ext?.terragruntDir?.isNotBlank() == true) {
        project.rootDir.resolve(ext.terragruntDir)
    } else {
        project.projectDir
    }
    val executor = TerragruntExecutor(
        workingDir = workDir,
        terragruntBinary = terragruntBinary.get()
    )
    // ... rest unchanged
}
```

Then each subproject build file points to its Terragrunt directory:

`terraform/environments/global/tfc/workspaces/build.gradle.kts`:

```kotlin
plugins {
    id("com.infiniteroomlabs.infrastructure")
}
infrastructure {
    localState = true
    terragruntDir = "terraform/environments/global/tfc/workspaces"
}
```

`terraform/environments/global/cloudflare/tokens/build.gradle.kts`:

```kotlin
plugins {
    id("com.infiniteroomlabs.infrastructure")
}
infrastructure {
    localState = true
    terragruntDir = "terraform/environments/global/cloudflare/tokens"
}
```

`terraform/environments/dev/cloudflare/zones/build.gradle.kts`:

```kotlin
plugins {
    id("com.infiniteroomlabs.infrastructure")
}
infrastructure {
    module = "cloudflare-zone"
    dependsOn(":global:cloudflare:tokens")
    terragruntDir = "terraform/environments/dev/cloudflare/zones"
}
```

`terraform/environments/dev/porkbun/nameservers/build.gradle.kts`:

```kotlin
plugins {
    id("com.infiniteroomlabs.infrastructure")
}
infrastructure {
    module = "porkbun-nameservers"
    dependsOn(":dev:cloudflare:zones")
    terragruntDir = "terraform/environments/dev/porkbun/nameservers"
}
```

`terraform/environments/prod/cloudflare/zones/build.gradle.kts`:

```kotlin
plugins {
    id("com.infiniteroomlabs.infrastructure")
}
infrastructure {
    module = "cloudflare-zone"
    dependsOn(":global:cloudflare:tokens")
    terragruntDir = "terraform/environments/prod/cloudflare/zones"
}
```

`terraform/environments/prod/porkbun/nameservers/build.gradle.kts`:

```kotlin
plugins {
    id("com.infiniteroomlabs.infrastructure")
}
infrastructure {
    module = "porkbun-nameservers"
    dependsOn(":prod:cloudflare:zones")
    terragruntDir = "terraform/environments/prod/porkbun/nameservers"
}
```

Also update `settings.gradle.kts` to set project dirs into the terraform tree:

```kotlin
infrastructure {
    // The settings plugin needs to know where subproject dirs actually live
    baseDir = "terraform/environments"

    environment("global") {
        provider("tfc") { resourceGroup("workspaces") }
        provider("cloudflare") { resourceGroup("tokens") }
    }
    // ... etc
}
```

Add `baseDir` to `InfrastructureSettingsExtension`:

```kotlin
var baseDir: String = ""  // relative to settings.rootDir
```

Update `IrlSettingsPlugin.registerSubprojects` to use it:

```kotlin
private fun registerSubprojects(settings: Settings, extension: InfrastructureSettingsExtension) {
    val base = if (extension.baseDir.isNotBlank()) extension.baseDir else ""

    for (env in extension.environments) {
        for (provider in env.providers) {
            for (rg in provider.resourceGroups) {
                val path = ":${env.name}:${provider.name}:$rg"
                settings.include(path)
                val project = settings.project(path)
                val dirPath = listOfNotNull(
                    base.takeIf { it.isNotBlank() },
                    env.name, provider.name, rg
                ).joinToString("/")
                project.projectDir = settings.rootDir.resolve(dirPath)
            }
        }
    }
}
```

**Step 5: Verify with a dry run**

```bash
cd ~/projects/infinite-room-labs/infinite-room-labs-infra
./gradlew projects
```

Expected output should list all 6 subprojects.

```bash
./gradlew :dev:cloudflare:zones:plan --dry-run
```

Expected: shows task execution order including `:global:cloudflare:tokens:init`, `:global:cloudflare:tokens:plan`, `:dev:cloudflare:zones:init`, `:dev:cloudflare:zones:plan`.

**Step 6: Run a real plan (requires credentials)**

```bash
./gradlew :dev:cloudflare:zones:plan
```

This requires `.env` to be loaded (direnv handles this). Should produce real Terraform plan output.

**Step 7: Commit both repos**

In `irl-gradle-plugin`:

```bash
cd ~/projects/infinite-room-labs/irl-gradle-plugin
git add -A
git commit -m "feat: add baseDir, terragruntDir, and maven-publish for local development"
```

In `infinite-room-labs-infra`:

```bash
cd ~/projects/infinite-room-labs/infinite-room-labs-infra
git add settings.gradle.kts build.gradle.kts terraform/environments/*/build.gradle.kts terraform/environments/*/*/build.gradle.kts terraform/environments/*/*/*/build.gradle.kts
git commit -m "feat: add Gradle plugin integration with infrastructure DSL"
```

---

## Task 9: Streaming Output

The current executor captures all output and prints it at the end. For long-running plans/applies, we need real-time streaming.

**Files:**
- Modify: `src/main/kotlin/com/infiniteroomlabs/gradle/engine/TerragruntExecutor.kt`
- Modify: `src/main/kotlin/com/infiniteroomlabs/gradle/tasks/TerragruntTask.kt`
- Test: `src/test/kotlin/com/infiniteroomlabs/gradle/engine/StreamingExecutorTest.kt`

**Step 1: Write the failing test**

`src/test/kotlin/com/infiniteroomlabs/gradle/engine/StreamingExecutorTest.kt`:

```kotlin
package com.infiniteroomlabs.gradle.engine

import org.junit.jupiter.api.Test
import org.junit.jupiter.api.Assertions.*
import org.junit.jupiter.api.io.TempDir
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.PrintStream

class StreamingExecutorTest {

    @TempDir
    lateinit var workDir: File

    @Test
    fun `executeStreaming pipes output to provided streams`() {
        val script = File(workDir, "test.sh")
        script.writeText("""
            #!/bin/bash
            echo "line1"
            echo "line2"
            echo "err1" >&2
        """.trimIndent())
        script.setExecutable(true)

        val stdout = ByteArrayOutputStream()
        val stderr = ByteArrayOutputStream()

        val executor = TerragruntExecutor(workDir)
        val exitCode = executor.executeStreaming(
            listOf(script.absolutePath),
            stdout = PrintStream(stdout),
            stderr = PrintStream(stderr)
        )

        assertEquals(0, exitCode)
        assertTrue(stdout.toString().contains("line1"))
        assertTrue(stdout.toString().contains("line2"))
        assertTrue(stderr.toString().contains("err1"))
    }
}
```

**Step 2: Run test to verify it fails**

```bash
./gradlew test
```

Expected: FAIL -- `executeStreaming` not found.

**Step 3: Add streaming execution**

Add to `TerragruntExecutor.kt`:

```kotlin
fun executeStreaming(
    command: List<String>,
    env: Map<String, String> = emptyMap(),
    stdout: PrintStream = System.out,
    stderr: PrintStream = System.err
): Int {
    val process = ProcessBuilder(command)
        .directory(workingDir)
        .apply { environment().putAll(env) }
        .start()

    // Stream stdout and stderr in separate threads
    val stdoutThread = Thread {
        process.inputStream.bufferedReader().forEachLine { stdout.println(it) }
    }
    val stderrThread = Thread {
        process.errorStream.bufferedReader().forEachLine { stderr.println(it) }
    }

    stdoutThread.start()
    stderrThread.start()

    val exitCode = process.waitFor()
    stdoutThread.join()
    stderrThread.join()

    return exitCode
}
```

Add import at top:

```kotlin
import java.io.PrintStream
```

Update `TerragruntTask.execute()` to use streaming:

```kotlin
@TaskAction
open fun execute() {
    val ext = project.extensions.findByType(InfrastructureExtension::class.java)
    val workDir = if (ext?.terragruntDir?.isNotBlank() == true) {
        project.rootDir.resolve(ext.terragruntDir)
    } else {
        project.projectDir
    }
    val executor = TerragruntExecutor(
        workingDir = workDir,
        terragruntBinary = terragruntBinary.get()
    )
    val command = executor.buildCommand(action.get(), extraArgs)
    val exitCode = executor.executeStreaming(command)

    if (exitCode != 0) {
        throw GradleException("terragrunt ${action.get()} failed with exit code $exitCode")
    }
}
```

**Step 4: Run tests to verify they pass**

```bash
./gradlew test
```

Expected: PASS.

**Step 5: Commit**

```bash
git add -A
git commit -m "feat: add streaming output for real-time plan/apply feedback"
```

---

## Task 10: Task Listing and Help

Users need to discover available tasks. Gradle's built-in `tasks` command should show infrastructure tasks grouped clearly.

**Files:**
- Test: `src/test/kotlin/com/infiniteroomlabs/gradle/TaskListingTest.kt`

**Step 1: Write the test**

`src/test/kotlin/com/infiniteroomlabs/gradle/TaskListingTest.kt`:

```kotlin
package com.infiniteroomlabs.gradle

import org.gradle.testkit.runner.GradleRunner
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import org.junit.jupiter.api.Assertions.*
import java.io.File

class TaskListingTest {

    @TempDir
    lateinit var testProjectDir: File

    private fun writeFile(path: String, content: String) {
        val file = File(testProjectDir, path)
        file.parentFile.mkdirs()
        file.writeText(content.trimIndent())
    }

    private fun writeFakeTerragrunt() {
        val bin = File(testProjectDir, "bin")
        bin.mkdirs()
        File(bin, "terragrunt").apply {
            writeText("#!/bin/bash\necho ok")
            setExecutable(true)
        }
    }

    @Test
    fun `tasks are grouped under Infrastructure heading`() {
        writeFakeTerragrunt()
        writeFile("settings.gradle.kts", """
            plugins {
                id("com.infiniteroomlabs.infrastructure.settings")
            }
            infrastructure {
                environment("dev") {
                    provider("cloudflare") {
                        resourceGroup("zones")
                    }
                }
            }
        """)
        writeFile("build.gradle.kts", """
            plugins {
                id("com.infiniteroomlabs.infrastructure")
            }
            infrastructure {
                terragruntBinary = "${'$'}{rootDir}/bin/terragrunt"
            }
        """)
        File(testProjectDir, "dev/cloudflare/zones").mkdirs()
        writeFile("dev/cloudflare/zones/build.gradle.kts", """
            plugins {
                id("com.infiniteroomlabs.infrastructure")
            }
        """)

        val result = GradleRunner.create()
            .withProjectDir(testProjectDir)
            .withPluginClasspath()
            .withArguments(":dev:cloudflare:zones:tasks", "--group", "infrastructure")
            .build()

        val output = result.output
        assertTrue(output.contains("Infrastructure tasks"))
        assertTrue(output.contains("init"))
        assertTrue(output.contains("plan"))
        assertTrue(output.contains("apply"))
        assertTrue(output.contains("destroy"))
        assertTrue(output.contains("output"))
        assertTrue(output.contains("validate"))
    }
}
```

**Step 2: Run test**

```bash
./gradlew test
```

Expected: PASS -- tasks already have `group = "infrastructure"` from Task 5.

**Step 3: Commit**

```bash
git add -A
git commit -m "test: verify infrastructure tasks are discoverable via tasks command"
```

---

## Summary

| Task | What It Builds | Key Test |
|------|---------------|----------|
| 1 | Project scaffold, stub plugins | Plugin applies without error |
| 2 | Settings plugin + DSL for subproject registration | `infrastructure {}` creates subprojects |
| 3 | Project extension for shared config | State backend, providers, local state configurable |
| 4 | TerragruntExecutor shell-out engine | Commands built correctly, stdout/stderr captured |
| 5 | Task types (init/validate/plan/apply/destroy/output) | Tasks execute correct terragrunt commands |
| 6 | DAG dependency wiring | Apply on downstream triggers upstream chain |
| 7 | Destroy safety gate | Destroy requires `-Pdestroy.confirm=true` |
| 8 | Proving ground integration | Real `./gradlew :dev:cloudflare:zones:plan` works |
| 9 | Streaming output | Real-time log streaming during plan/apply |
| 10 | Task listing and help | Tasks grouped under "Infrastructure" |

**After all 10 tasks:** `./gradlew :dev:porkbun:nameservers:apply` in the infra repo triggers the full chain (bootstrap tokens -> zones -> nameservers) with real-time streaming output, matching the current `terragrunt run-all apply` behavior but with explicit DAG control.
