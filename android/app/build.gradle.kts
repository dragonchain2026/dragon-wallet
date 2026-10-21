import java.util.Properties
import java.util.Base64
import java.net.URI

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseKeyFile = System.getenv("DRAGON_SIGNING_DIR")?.let { file("$it/key.properties") }
    ?: rootProject.file("../../private/android-signing/key.properties")
val releaseKeys = Properties()
if (releaseKeyFile.isFile) {
    releaseKeyFile.inputStream().use { releaseKeys.load(it) }
}
if (gradle.startParameter.taskNames.any { it.contains("release", ignoreCase = true) }) {
    check(releaseKeyFile.isFile) { "Release signing keys missing: private/android-signing/key.properties" }
}

// Flutter forwards dart-defines to Gradle as base64-encoded key=value entries.
// Generate HTTP exceptions from the same build configuration as the Dart client.
val deploymentDefines = providers.gradleProperty("dart-defines").orNull
    .orEmpty().split(",").filter { it.isNotEmpty() }.associate { encoded ->
        val pair = String(Base64.getDecoder().decode(encoded), Charsets.UTF_8)
            .split("=", limit = 2)
        pair[0] to pair.getOrElse(1) { "" }
    }
val httpHosts = listOf("WALLET_API_URL", "CEX_URL").mapNotNull { key ->
    deploymentDefines[key]?.takeIf { it.isNotBlank() }?.let { value ->
        val uri = URI(value)
        require(uri.scheme in listOf("http", "https") && uri.host != null &&
            uri.rawUserInfo == null && uri.rawQuery == null && uri.rawFragment == null &&
            uri.path in listOf("", "/")) { "Invalid deployment URL in $key" }
        if (uri.scheme == "http") uri.host else null
    }
}.distinct()
val networkResources = layout.buildDirectory.dir("generated/deploymentNetwork/res")
val generateDeploymentNetwork = tasks.register("generateDeploymentNetwork") {
    inputs.property("httpHosts", httpHosts)
    outputs.dir(networkResources)
    doLast {
        val xmlDir = networkResources.get().dir("xml").asFile.apply { mkdirs() }
        fun writeConfig(name: String, hosts: List<String>) {
            val domains = hosts.distinct().joinToString("\n") {
                "        <domain includeSubdomains=\"false\">$it</domain>"
            }
            val exception = if (domains.isEmpty()) "" else
                "    <domain-config cleartextTrafficPermitted=\"true\">\n$domains\n    </domain-config>\n"
            xmlDir.resolve("$name.xml").writeText(
                "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<network-security-config>\n" +
                    "    <base-config cleartextTrafficPermitted=\"false\"/>\n" +
                    exception + "</network-security-config>\n")
        }
        writeConfig("wallet_network_security", httpHosts)
        writeConfig("debug_network_security", httpHosts + listOf("localhost", "127.0.0.1", "10.0.2.2"))
    }
}
tasks.named("preBuild") { dependsOn(generateDeploymentNetwork) }

android {
    sourceSets.getByName("main").res.srcDir(networkResources.get().asFile)
    namespace = "org.dragonwallet.dragon_wallet"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "org.dragonwallet.dragon_wallet"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        externalNativeBuild {
            cmake { targets += "dragon_keys_jni" }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("../../native/dragon_wallet_core/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    signingConfigs {
        if (releaseKeyFile.isFile) {
            create("release") {
                storeFile = releaseKeyFile.parentFile.resolve(releaseKeys.getProperty("storeFile"))
                storeType = releaseKeys.getProperty("storeType", "PKCS12")
                storePassword = releaseKeys.getProperty("storePassword")
                keyPassword = releaseKeys.getProperty("keyPassword")
                keyAlias = releaseKeys.getProperty("keyAlias")
            }
        }
    }

    buildTypes {
        debug {
            val emulatorEnvironment = providers.gradleProperty("dragonEmulatorEnvironment").orNull
            if (emulatorEnvironment in listOf("local", "prod")) {
                applicationIdSuffix = if (emulatorEnvironment == "prod") ".remote" else ".local"
            }
        }
        release {
            signingConfig = signingConfigs.findByName("release")
            proguardFiles("proguard-rules.pro")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
}
