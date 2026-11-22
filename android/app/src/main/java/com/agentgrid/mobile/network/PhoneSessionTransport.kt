package com.agentgrid.mobile.network

import java.net.Proxy
import java.security.MessageDigest
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLContext
import javax.net.ssl.X509TrustManager
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import okhttp3.ConnectionSpec
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener

internal fun normalizedPhoneHost(host: String): String? {
    if (host.isEmpty() || host.any { it.isWhitespace() || it in "@/\\?#%" }) return null
    return runCatching { HttpUrl.Builder().scheme("http").host(host).build().host }.getOrNull()
}

internal class OkHttpPhoneSessionTransport : PhoneSessionTransport {
    private val mutableEvents = MutableSharedFlow<TransportEvent>(extraBufferCapacity = 64)
    override val events: Flow<TransportEvent> = mutableEvents
    private val httpClient = OkHttpClient.Builder()
        .pingInterval(20, TimeUnit.SECONDS)
        .followRedirects(false)
        .followSslRedirects(false)
        .retryOnConnectionFailure(true)
        .build()

    private var socket: WebSocket? = null
    private var generation = 0L

    @Synchronized
    override fun connect(endpoint: PhoneEndpoint) {
        val currentGeneration = ++generation
        socket?.cancel()
        socket = null
        val (client, request) = runCatching {
            val host = requireNotNull(normalizedPhoneHost(endpoint.host))
            val tls = endpoint.tls
            // OkHttp upgrades an http(s) URL using WebSocket; https always means wss here.
            val url = HttpUrl.Builder().scheme(if (tls == null) "http" else "https")
                .host(host).port(endpoint.port).addPathSegment("agentgrid").build()
            val builder = Request.Builder().url(url)
            if (tls == null) {
                // Legacy macOS/upstream pairing sends no secret at upgrade time.
                httpClient to builder.build()
            } else {
                val trust = PhoneCertificateTrust(tls.certificateSha256)
                val context = SSLContext.getInstance("TLS").apply { init(null, arrayOf(trust), null) }
                httpClient.newBuilder()
                    .proxy(Proxy.NO_PROXY)
                    .connectionSpecs(listOf(ConnectionSpec.MODERN_TLS))
                    .sslSocketFactory(context.socketFactory, trust)
                    // The out-of-band leaf pin authenticates this specific Bridge. Its IP may
                    // change, so the self-signed certificate does not encode a hostname or IP.
                    .hostnameVerifier { actualHost, _ -> actualHost == host }
                    .build() to builder.header("Authorization", "Bearer ${tls.secret}").build()
            }
        }.getOrElse {
            mutableEvents.tryEmit(TransportEvent.Failed(null))
            return
        }
        socket = client.newWebSocket(
            request,
            object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) =
                    withCurrent(webSocket, currentGeneration) { mutableEvents.tryEmit(TransportEvent.Opened) }

                override fun onMessage(webSocket: WebSocket, text: String) =
                    withCurrent(webSocket, currentGeneration) { mutableEvents.tryEmit(TransportEvent.TextReceived(text)) }

                override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                    webSocket.close(1000, null)
                }

                override fun onClosed(webSocket: WebSocket, code: Int, reason: String) =
                    withCurrent(webSocket, currentGeneration) {
                        socket = null
                        mutableEvents.tryEmit(TransportEvent.Closed(null))
                    }

                override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) =
                    withCurrent(webSocket, currentGeneration) {
                        socket = null
                        // Do not propagate exception text, URLs, response bodies, or headers.
                        mutableEvents.tryEmit(TransportEvent.Failed(null))
                    }
            },
        )
    }

    @Synchronized
    override fun send(text: String): Boolean = socket?.send(text) == true

    @Synchronized
    override fun disconnect() {
        generation += 1
        socket?.close(1000, null)
        socket = null
    }

    @Synchronized
    override fun close() {
        disconnect()
        httpClient.dispatcher.executorService.shutdown()
        httpClient.connectionPool.evictAll()
    }

    private inline fun withCurrent(webSocket: WebSocket, eventGeneration: Long, block: () -> Unit) {
        synchronized(this) {
            if (generation == eventGeneration && socket === webSocket) block()
        }
    }
}

private class PhoneCertificateTrust(certificateSha256: String) : X509TrustManager {
    private val expected = certificateSha256.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {
        val leaf = chain?.firstOrNull() ?: throw CertificateException("Bridge TLS identity missing")
        val actual = MessageDigest.getInstance("SHA-256").digest(leaf.encoded)
        if (!MessageDigest.isEqual(actual, expected)) throw CertificateException("Bridge TLS identity mismatch")
        leaf.checkValidity()
    }

    override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) {
        throw CertificateException("Client certificates are not supported")
    }

    override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
}
