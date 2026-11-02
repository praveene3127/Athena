plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.athena.reading"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.athena.reading"
        minSdk = 24
        targetSdk = 36
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            val keystoreProp = project.findProperty("KEYSTORE_PATH") as String?
            val customKeystore = if (keystoreProp != null) file(keystoreProp) else null
            val defaultKeystore = File(project.rootDir, "../../releases/athena-release.keystore")
            val targetKeystore = when {
                customKeystore != null && customKeystore.exists() -> customKeystore
                defaultKeystore.exists() -> defaultKeystore
                else -> null
            }
            if (targetKeystore != null) {
                storeFile = targetKeystore
                storePassword = (project.findProperty("KEYSTORE_PASSWORD") as String?) ?: "athena123"
                keyAlias = (project.findProperty("KEY_ALIAS") as String?) ?: "athena"
                keyPassword = (project.findProperty("KEY_PASSWORD") as String?) ?: "athena123"
            } else {
                val debug = signingConfigs.getByName("debug")
                storeFile = debug.storeFile
                storePassword = debug.storePassword
                keyAlias = debug.keyAlias
                keyPassword = debug.keyPassword
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
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
