import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "org.neforum.neforum_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications uses java.time on older Android versions.
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "org.neforum.app"
        // flutter_secure_storage 10+, url_launcher and image_picker need API 24.
        minSdk = maxOf(24, flutter.minSdkVersion)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        // Release builds are signed with a key from key.properties when present
        // (CI), otherwise with the debug key so `flutter run --release` works.
        // (Inside android { }, `java` is the Android java extension, hence the
        // import at the top instead of java.util.Properties here.)
        val props = Properties()
        val keyFile = rootProject.file("key.properties")
        if (keyFile.exists()) {
            keyFile.inputStream().use { stream -> props.load(stream) }
            create("release") {
                storeFile = project.file(props.getProperty("storeFile"))
                storePassword = props.getProperty("storePassword")
                keyAlias = props.getProperty("keyAlias")
                keyPassword = props.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
        }
    }

    // Compress the native code (Flutter engine, compiled Dart) inside the APK
    // instead of storing it raw: the APK roughly halves, and each per-ABI APK
    // stays under the 25 MiB per-file limit of the neforus.com mirror. Android
    // unpacks it once at install.
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
    // Video caption compositor (VideoCompositor.kt): re-encodes a video with
    // the caption block drawn in.
    implementation("androidx.media3:media3-transformer:1.8.0")
    implementation("androidx.media3:media3-effect:1.8.0")
    implementation("androidx.media3:media3-common:1.8.0")
}

flutter {
    source = "../.."
}
