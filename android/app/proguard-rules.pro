# App-specific R8 rules belong here. There are currently no app-specific keep
# rules: the app and shared module use kotlinx.serialization's JsonElement tree
# API directly, not reflection or generated @Serializable serializers. Android
# manifest entry points and dependency consumer rules are handled by the Android
# Gradle plugin and R8's merged default configuration.

# OkHttp probes these optional JVM TLS providers when their classes are present.
# Android uses its platform TLS provider, so none of these optional integrations
# are packaged in the app. Suppress only the absent provider types R8 reports.
-dontwarn org.bouncycastle.jsse.BCSSLParameters
-dontwarn org.bouncycastle.jsse.BCSSLSocket
-dontwarn org.bouncycastle.jsse.provider.BouncyCastleJsseProvider
-dontwarn org.conscrypt.Conscrypt$Version
-dontwarn org.conscrypt.Conscrypt
-dontwarn org.conscrypt.ConscryptHostnameVerifier
-dontwarn org.openjsse.javax.net.ssl.SSLParameters
-dontwarn org.openjsse.javax.net.ssl.SSLSocket
-dontwarn org.openjsse.net.ssl.OpenJSSE
