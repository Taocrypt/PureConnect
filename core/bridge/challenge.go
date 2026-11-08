package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"time"

	"github.com/mythologyli/zju-connect/client/authchallenge"
)

const challengeTimeout = 5 * time.Minute

var errChallengeCancelled = errors.New("authentication cancelled by user")

// uiChallengeHandler implements authchallenge.Handler by asking the UI over
// the protocol channel and blocking until it answers.
type uiChallengeHandler struct {
	em      *emitter
	workDir string

	nextID  atomic.Int64
	mu      sync.Mutex
	pending map[int64]chan ChallengeResponse
}

func newUIChallengeHandler(em *emitter, workDir string) *uiChallengeHandler {
	if workDir == "" {
		workDir = os.TempDir()
	}
	return &uiChallengeHandler{em: em, workDir: workDir, pending: map[int64]chan ChallengeResponse{}}
}

// deliver routes a challenge_response command to the waiting challenge.
func (h *uiChallengeHandler) deliver(id int64, resp ChallengeResponse) {
	h.mu.Lock()
	ch, ok := h.pending[id]
	delete(h.pending, id)
	h.mu.Unlock()
	if ok {
		ch <- resp
	}
}

// cancelAll unblocks every pending challenge (used on stop).
func (h *uiChallengeHandler) cancelAll() {
	h.mu.Lock()
	defer h.mu.Unlock()
	for id, ch := range h.pending {
		ch <- ChallengeResponse{Cancel: true}
		delete(h.pending, id)
	}
}

func (h *uiChallengeHandler) ask(ev Event) (ChallengeResponse, error) {
	id := h.nextID.Add(1)
	ch := make(chan ChallengeResponse, 1)
	h.mu.Lock()
	h.pending[id] = ch
	h.mu.Unlock()

	ev.Type = "challenge"
	ev.ID = id
	h.em.emit(ev)

	select {
	case resp := <-ch:
		if resp.Cancel {
			return resp, errChallengeCancelled
		}
		return resp, nil
	case <-time.After(challengeTimeout):
		h.mu.Lock()
		delete(h.pending, id)
		h.mu.Unlock()
		return ChallengeResponse{}, fmt.Errorf("authentication challenge timed out after %s", challengeTimeout)
	}
}

func (h *uiChallengeHandler) writeImage(prefix string, img []byte) (string, error) {
	if err := os.MkdirAll(h.workDir, 0o700); err != nil {
		return "", err
	}
	path := filepath.Join(h.workDir, fmt.Sprintf("%s-%d.img", prefix, time.Now().UnixNano()))
	if err := os.WriteFile(path, img, 0o600); err != nil {
		return "", err
	}
	return path, nil
}

func (h *uiChallengeHandler) HandleCodeChallenge(c authchallenge.CodeChallenge) (authchallenge.CodeResponse, error) {
	resp, err := h.ask(Event{Kind: "code", CodeKind: string(c.Kind), Message: c.Message, CanSkip: c.CanSkipSecondaryAuth})
	if err != nil {
		return authchallenge.CodeResponse{}, err
	}
	if resp.Code == "" && !resp.SkipSecondaryAuth {
		return authchallenge.CodeResponse{}, errors.New("authentication code is empty")
	}
	return authchallenge.CodeResponse{Code: resp.Code, SkipSecondaryAuth: resp.SkipSecondaryAuth && c.CanSkipSecondaryAuth}, nil
}

func (h *uiChallengeHandler) HandleTextCaptcha(c authchallenge.TextCaptchaChallenge) (authchallenge.TextCaptchaResponse, error) {
	path, err := h.writeImage("captcha", c.Image)
	if err != nil {
		return authchallenge.TextCaptchaResponse{}, fmt.Errorf("write captcha image: %w", err)
	}
	defer os.Remove(path)
	resp, err := h.ask(Event{Kind: "text_captcha", Message: c.Message, ImagePath: path})
	if err != nil {
		return authchallenge.TextCaptchaResponse{}, err
	}
	out := authchallenge.TextCaptchaResponse{Code: resp.Code}
	return out, c.Validate(out)
}

func (h *uiChallengeHandler) HandleClickCaptcha(c authchallenge.ClickCaptchaChallenge) (authchallenge.ClickCaptchaResponse, error) {
	path, err := h.writeImage("click-captcha", c.Image)
	if err != nil {
		return authchallenge.ClickCaptchaResponse{}, fmt.Errorf("write captcha image: %w", err)
	}
	defer os.Remove(path)
	resp, err := h.ask(Event{Kind: "click_captcha", Message: c.Message, ImagePath: path})
	if err != nil {
		return authchallenge.ClickCaptchaResponse{}, err
	}
	if len(resp.Points) == 0 {
		return authchallenge.ClickCaptchaResponse{}, errors.New("click captcha response is empty")
	}
	points := make([]authchallenge.Point, 0, len(resp.Points))
	for _, p := range resp.Points {
		points = append(points, authchallenge.Point{X: p.X, Y: p.Y})
	}
	return authchallenge.ClickCaptchaResponse{Points: points, Width: resp.Width, Height: resp.Height}, nil
}

func (h *uiChallengeHandler) HandleExternalLogin(c authchallenge.ExternalLoginChallenge) (authchallenge.ExternalLoginResponse, error) {
	resp, err := h.ask(Event{Kind: "external_login", CodeKind: string(c.Kind), Message: c.Message, LoginURL: c.LoginURL})
	if err != nil {
		return authchallenge.ExternalLoginResponse{}, err
	}
	if resp.CallbackURL == "" {
		return authchallenge.ExternalLoginResponse{}, errors.New("callback URL is empty")
	}
	return authchallenge.ExternalLoginResponse{CallbackURL: resp.CallbackURL}, nil
}
