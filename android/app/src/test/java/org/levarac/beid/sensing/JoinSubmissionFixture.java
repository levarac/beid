package org.levarac.beid.sensing;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import kotlin.coroutines.Continuation;
import kotlinx.coroutines.CoroutineScope;
import org.levarac.parallax.registry.EventDefinition;
import org.levarac.parallax.registry.EventDefinitionContext;
import org.levarac.parallax.registry.EventDefinitionResolution;
import org.levarac.parallax.submission.SubmissionClient;
import org.levarac.parallax.submission.SubmissionHttpRequest;
import org.levarac.parallax.submission.SubmissionHttpResponse;
import org.levarac.parallax.submission.SubmissionHttpTransport;
import org.levarac.parallax.submission.SubmissionOperatorConfiguration;

/** JVM-only fixtures: Kotlin internal constructors are accessible from Java.
 * Keeps fake registry answers and an in-memory HTTP transport out of the shared API.
 * The real join issuer, observation signer, stores and submission client still run.
 */
public final class JoinSubmissionFixture implements SubmissionHttpTransport {
    public static final class Request {
        public final String method;
        public final String url;
        public final byte[] body;

        Request(SubmissionHttpRequest request) {
            method = request.getMethod();
            url = request.getUrl();
            body = request.getBody() == null ? null : request.getBody().clone();
        }
    }

    public final List<Request> requests = new ArrayList<>();

    public SubmissionClient client(CoroutineScope scope) {
        return new SubmissionClient(this, scope);
    }

    @Override
    public Object execute(SubmissionHttpRequest request,
            Continuation<? super SubmissionHttpResponse> continuation) {
        requests.add(new Request(request));
        // A missing receipt permits retrying the exact bytes. A temporary POST
        // failure leaves the window queued, so no receipt fixture is needed.
        return new SubmissionHttpResponse(request.getMethod().equals("GET") ? 404 : 503,
                new byte[0], Collections.emptyMap());
    }

    public static EventDefinitionResolution withSubmissionConfiguration(
            EventDefinitionResolution base, SubmissionOperatorConfiguration configuration) {
        EventDefinitionContext context = base.getContext();
        EventDefinition original = context.getDefinition();
        EventDefinition definition = new EventDefinition(
                original.getVersion(), original.getEventId(), original.getRegistrar(),
                original.getAnchorOperator(), original.getNonce(), original.getKeySetDigest(),
                original.getSequence(), original.getPreviousDefinitionDigest(),
                configuration.getReceiptPublicKey(), configuration.getOperatorId(),
                configuration.getSubmissionEndpoint(), original.getValidFrom(), original.getValidUntil(),
                original.getAuthorityPublicKey(), original.getJoinMode(),
                hexBytes(original.getEventCodeHashHex()), original.getOrganizerClaim());
        return new EventDefinitionResolution(true,
                new EventDefinitionContext(context.getEventIdHex(), context.getDefinitionHashHex(),
                        context.getSelectedAt(), context.getRecord(), definition),
                base.getBlockNumber(), base.getBlockHashHex(), base.getDefinitionHashHex(), null, null);
    }

    private static byte[] hexBytes(String hex) {
        byte[] bytes = new byte[hex.length() / 2];
        for (int i = 0; i < bytes.length; i++) {
            bytes[i] = (byte) Integer.parseInt(hex.substring(i * 2, i * 2 + 2), 16);
        }
        return bytes;
    }
}
