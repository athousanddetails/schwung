// Where a module install/update sends you afterwards.
//
// moduleRedirect used to read only the Referer, and every response sets
// `Referrer-Policy: no-referrer` — so the header is always absent and the
// `/modules/<id>` fallback fired on every install. Installing from the module
// list therefore dumped you on that module's detail page, which is the whole
// complaint: with a filter set and several modules to install, you lost your
// place every time.
//
// The form now states where it came from. These pin the parts that fail
// quietly: the precedence, and the refusal of a return_to that points off this
// server.

package main

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

func TestSafeReturnToRejectsOffSiteDestinations(t *testing.T) {
	for _, bad := range []string{
		"",                       // absent
		"https://evil.example/x", // absolute
		"//evil.example/x",       // protocol-relative — a browser leaves the host
		"/\\evil.example",        // backslash smuggling
		"modules",                // not rooted
		" /modules",              // leading space, not rooted
	} {
		if got := safeReturnTo(bad); got != "" {
			t.Errorf("safeReturnTo(%q) = %q, want \"\" (refused)", bad, got)
		}
	}
	for _, good := range []string{"/modules", "/modules?sort=az", "/"} {
		if got := safeReturnTo(good); got != good {
			t.Errorf("safeReturnTo(%q) = %q, want it accepted", good, got)
		}
	}
}

// The regression itself: no Referer (which is ALWAYS the case here), but the
// form says where it came from, so we must not fall back to the detail page.
func TestModuleRedirectPrefersReturnTo(t *testing.T) {
	app := &App{}

	form := url.Values{"return_to": {"/modules"}}
	r := httptest.NewRequest(http.MethodPost, "/modules/minijv/install",
		strings.NewReader(form.Encode()))
	r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	// Deliberately NO Referer — that is the live configuration.
	w := httptest.NewRecorder()

	app.moduleRedirect(w, r, "minijv", "ok")

	loc := w.Header().Get("Location")
	if !strings.HasPrefix(loc, "/modules?flash=") {
		t.Fatalf("Location = %q, want a redirect back to /modules", loc)
	}
	if strings.Contains(loc, "/modules/minijv") {
		t.Fatalf("Location = %q — fell back to the module detail page, which is the bug", loc)
	}
}

// Without a return_to and without a Referer there is nothing better to do than
// the detail page, so that behaviour must survive.
func TestModuleRedirectFallsBackWhenNothingSaysOtherwise(t *testing.T) {
	app := &App{}
	r := httptest.NewRequest(http.MethodPost, "/modules/minijv/install", nil)
	w := httptest.NewRecorder()

	app.moduleRedirect(w, r, "minijv", "ok")

	if loc := w.Header().Get("Location"); !strings.HasPrefix(loc, "/modules/minijv?flash=") {
		t.Fatalf("Location = %q, want the detail-page fallback", loc)
	}
}

// An off-site return_to must be ignored rather than followed.
func TestModuleRedirectIgnoresOffSiteReturnTo(t *testing.T) {
	app := &App{}
	form := url.Values{"return_to": {"https://evil.example/"}}
	r := httptest.NewRequest(http.MethodPost, "/modules/minijv/install",
		strings.NewReader(form.Encode()))
	r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	w := httptest.NewRecorder()

	app.moduleRedirect(w, r, "minijv", "ok")

	loc := w.Header().Get("Location")
	if strings.Contains(loc, "evil.example") {
		t.Fatalf("Location = %q — followed an off-site return_to", loc)
	}
}

// An absolute same-origin Referer still works, for a deployment that relaxed
// the policy: reducing it to a path must not turn into the detail-page fallback.
func TestModuleRedirectAcceptsAbsoluteReferer(t *testing.T) {
	app := &App{}
	r := httptest.NewRequest(http.MethodPost, "/modules/minijv/install", nil)
	r.Header.Set("Referer", "http://move.local:7700/modules?sort=az")
	w := httptest.NewRecorder()

	app.moduleRedirect(w, r, "minijv", "ok")

	loc := w.Header().Get("Location")
	if !strings.HasPrefix(loc, "/modules?sort=az") {
		t.Fatalf("Location = %q, want the Referer's path and query preserved", loc)
	}
}

// Installing several in a row must not stack flashes on the URL.
func TestModuleRedirectDoesNotStackFlashes(t *testing.T) {
	app := &App{}
	form := url.Values{"return_to": {"/modules?flash=Something+installed"}}
	r := httptest.NewRequest(http.MethodPost, "/modules/minijv/install",
		strings.NewReader(form.Encode()))
	r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	w := httptest.NewRecorder()

	app.moduleRedirect(w, r, "minijv", "ok")

	if loc := w.Header().Get("Location"); strings.Count(loc, "flash=") != 1 {
		t.Fatalf("Location = %q, want exactly one flash", loc)
	}
}
