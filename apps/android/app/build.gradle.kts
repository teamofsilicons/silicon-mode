plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

// apps/android -> repo root. Brand fonts live once, in shared/design/fonts.
val repoDir: File = rootDir.parentFile.parentFile
val sharedFontsDir = File(repoDir, "shared/design/fonts")

// Release signing is NOT configured yet (see docs/ANDROID.md). When these variables are set the
// release build is signed with that key; otherwise the release APK/AAB is unsigned.
data class ReleaseKey(val store: File, val alias: String, val storePassword: String, val keyPassword: String)

val releaseKey: ReleaseKey? = System.getenv("SILICON_MODE_ANDROID_KEYSTORE_PATH")?.let { path ->
    ReleaseKey(
        store = file(path),
        alias = System.getenv("SILICON_MODE_ANDROID_KEY_ALIAS") ?: "silicon-mode",
        storePassword = requireNotNull(System.getenv("SILICON_MODE_ANDROID_KEYSTORE_PASSWORD")) { "SILICON_MODE_ANDROID_KEYSTORE_PASSWORD is not set" },
        keyPassword = requireNotNull(System.getenv("SILICON_MODE_ANDROID_KEY_PASSWORD")) { "SILICON_MODE_ANDROID_KEY_PASSWORD is not set" },
    )
}

android {
    namespace = "ai.tos.mode"
    compileSdk = 36

    defaultConfig {
        applicationId = "ai.tos.mode"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
        // Silicon Cell `silicon-mode` (backend/README.md). The publishable key is public by design.
        buildConfigField("String", "CELL_URL", "\"https://silicon-mode.cells.teamofsilicons.com\"")
        buildConfigField("String", "CELL_PUBLISHABLE_KEY", "\"cs_publishable_59pEz0JOT9tBU-XxYS_dmDkiY1yUxmhXjKpNP-gzdVk\"")
        buildConfigField("String", "CELL_APP", "\"silicon-mode\"")
        // The cell only redirects to exact http(s) URLs; this page forwards the token fragment to
        // ai.tos.mode://auth/callback (docs/research/cells.md §2.3).
        buildConfigField("String", "SIGN_IN_REDIRECT", "\"https://mode.teamofsilicons.com/auth/android\"")
        buildConfigField("String", "WEB_URL", "\"https://mode.teamofsilicons.com\"")
        buildConfigField("String", "SOURCE_URL", "\"https://github.com/teamofsilicons/silicon-mode\"")
    }

    signingConfigs {
        if (releaseKey != null) {
            create("release") {
                storeFile = releaseKey.store
                storePassword = releaseKey.storePassword
                keyAlias = releaseKey.alias
                keyPassword = releaseKey.keyPassword
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            if (releaseKey != null) {
                signingConfig = signingConfigs.getByName("release")
            } else {
                logger.info("Silicon Mode: no release signing key configured; the release build is unsigned.")
            }
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    testOptions {
        unitTests.isReturnDefaultValues = true
    }

    packaging {
        resources.excludes += listOf("META-INF/*.version", "META-INF/LICENSE*", "META-INF/NOTICE*", "DebugProbesKt.bin")
    }
}

// Allo (the Silicon Accounts typeface) is copied from shared/design/fonts into a generated resource
// directory under a valid resource name, instead of being duplicated in this module.
abstract class SyncBrandResources : DefaultTask() {
    @get:InputDirectory
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val fontsDir: DirectoryProperty

    @get:OutputDirectory
    abstract val outputDir: DirectoryProperty

    @get:Inject
    abstract val fs: FileSystemOperations

    @TaskAction
    fun sync() {
        val root = fontsDir.get().asFile
        fs.sync {
            into(outputDir)
            from(File(root, "variable/AlloVariable.ttf")) {
                into("font")
                rename { "allo_variable.ttf" }
            }
        }
    }
}

val syncBrandResources = tasks.register<SyncBrandResources>("syncBrandResources") {
    fontsDir.set(sharedFontsDir)
    outputDir.set(layout.buildDirectory.dir("generated/silicon/res"))
}

androidComponents {
    onVariants { variant ->
        variant.sources.res?.addGeneratedSourceDirectory(syncBrandResources, SyncBrandResources::outputDir)
    }
}

dependencies {
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.foundation)
    implementation(libs.compose.material3)
    implementation(libs.compose.ui.tooling.preview)
    debugImplementation(libs.compose.ui.tooling)
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.browser)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.process)
    implementation(libs.okhttp)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.coil.compose)
    implementation(libs.coil.network.okhttp)
    testImplementation(libs.junit)
}
