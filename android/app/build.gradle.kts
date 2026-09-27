plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseSigningRequested =
    providers.environmentVariable("ANDROID_REQUIRE_RELEASE_SIGNING").orNull == "true" ||
        !providers.environmentVariable("ANDROID_KEYSTORE_PATH").orNull.isNullOrBlank()

android {
    namespace = "dev.echcanary.ech_canary"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "dev.echcanary.ech_canary"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Split APKs add Flutter's ABI offset to this build number.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (releaseSigningRequested) {
            create("release") {
                fun signingValue(name: String): String =
                    providers.environmentVariable(name).orNull?.takeIf { it.isNotBlank() }
                        ?: throw GradleException("Missing required Android signing variable: $name")

                val keystore = file(signingValue("ANDROID_KEYSTORE_PATH"))
                require(keystore.isFile) { "Android release keystore does not exist." }
                storeFile = keystore
                storePassword = signingValue("ANDROID_KEYSTORE_PASSWORD")
                keyAlias = signingValue("ANDROID_KEY_ALIAS")
                keyPassword = signingValue("ANDROID_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            // Required release signing must never fall back to the debug key.
            signingConfig = signingConfigs.getByName(
                if (releaseSigningRequested) "release" else "debug",
            )
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
