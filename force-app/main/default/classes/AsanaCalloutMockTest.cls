/**
 * Shared HttpCalloutMock for Asana integration tests.
 *
 * Records every request it receives (so tests can assert on method,
 * endpoint, and JSON body) and returns a configurable canned response.
 *
 * By default:
 *   - POST (create) -> 200 with {"data":{"gid":"<gidToReturn>"}}
 *   - PUT  (update) -> 200 with {"data":{}}
 *
 * Override responseStatusCode / responseBody to simulate failures.
 */
@isTest
public class AsanaCalloutMockTest implements HttpCalloutMock {

    public Integer callCount = 0;
    public List<HttpRequest> capturedRequests = new List<HttpRequest>();

    public Integer responseStatusCode = 200;
    public String responseBody = null; // null = auto-generate based on verb
    public String gidToReturn = '999999999';

    // Optional: return a DIFFERENT gid for each successive POST (create)
    // callout, in order (1st POST gets gidSequence[0], 2nd POST gets
    // gidSequence[1], etc). Falls back to gidToReturn once the sequence
    // runs out, or if this is left null. Useful for simulating "two
    // different Opportunities each get their own real Asana gid back."
    public List<String> gidSequence = null;
    private Integer postsSoFar = 0;

    public HttpResponse respond(HttpRequest req) {
        callCount++;
        capturedRequests.add(req);

        HttpResponse res = new HttpResponse();
        res.setStatusCode(responseStatusCode);

        if (responseBody != null) {
            res.setBody(responseBody);
        } else if (req.getMethod() == 'POST') {
            String gid = gidToReturn;
            if (gidSequence != null && postsSoFar < gidSequence.size()) {
                gid = gidSequence[postsSoFar];
            }
            postsSoFar++;
            res.setBody('{"data":{"gid":"' + gid + '"}}');
        } else {
            res.setBody('{"data":{}}');
        }
        return res;
    }

    // ---------- convenience helpers for assertions ----------

    public Integer postCount() {
        Integer n = 0;
        for (HttpRequest r : capturedRequests) {
            if (r.getMethod() == 'POST') n++;
        }
        return n;
    }

    public Integer putCount() {
        Integer n = 0;
        for (HttpRequest r : capturedRequests) {
            if (r.getMethod() == 'PUT') n++;
        }
        return n;
    }

    public HttpRequest lastRequest() {
        return capturedRequests.isEmpty() ? null : capturedRequests[capturedRequests.size() - 1];
    }

    public HttpRequest lastPost() {
        HttpRequest found = null;
        for (HttpRequest r : capturedRequests) {
            if (r.getMethod() == 'POST') found = r;
        }
        return found;
    }

    public HttpRequest lastPut() {
        HttpRequest found = null;
        for (HttpRequest r : capturedRequests) {
            if (r.getMethod() == 'PUT') found = r;
        }
        return found;
    }
}