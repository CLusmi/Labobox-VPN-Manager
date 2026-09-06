package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"embed"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"html/template"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

type Config struct {
	Port         string `json:"port"`
	AdminUser    string `json:"admin_user"`
	LiveEnabled  *bool  `json:"live_enabled,omitempty"`
	LiveInterval *int   `json:"live_interval,omitempty"`
	Domain       string `json:"domain,omitempty"`
	SFTPPort     string `json:"sftp_port,omitempty"`
}

type Tracker struct {
	Name string `json:"name"`
	URL  string `json:"url"`
}

type PaymentHistory struct {
	Date   string  `json:"date"`
	Amount float64 `json:"amount"`
	Method string  `json:"method"`
	Note   string  `json:"note"`
}

type Subscription struct {
	DueDate   string           `json:"due_date"`
	Suspended bool             `json:"suspended"`
	History   []PaymentHistory `json:"history"`
}

type SubscriptionsData map[string]*Subscription

type SubscriptionInfo struct {
	DueDate       string           `json:"due_date"`
	DueDateFR     string           `json:"due_date_fr"`
	DaysRemaining int              `json:"days_remaining"`
	Suspended     bool             `json:"suspended"`
	Status        string           `json:"status"`
	History       []PaymentHistory `json:"history"`
}

// Structures pour les statistiques de bande passante
type BandwidthHistory struct {
	Date     string `json:"date"`
	Download int64  `json:"download"`
	Upload   int64  `json:"upload"`
}

type BandwidthClientStats struct {
	Current    map[string]int64   `json:"current"`
	TodayDelta map[string]int64   `json:"today_delta"`
	TodayDate  string             `json:"today_date"`
	Updated    string             `json:"updated"`
	History    []BandwidthHistory `json:"history"`
}

type BandwidthResponse struct {
	Download      int64              `json:"download"`
	Upload        int64              `json:"upload"`
	DownloadToday int64              `json:"download_today"`
	UploadToday   int64              `json:"upload_today"`
	Updated       string             `json:"updated"`
	History       []BandwidthHistory `json:"history"`
	// Renseigné uniquement pour l'agrégat admin : total par client (30 jours),
	// trié décroissant, pour le classement « Top consommateurs ».
	Clients []BandwidthClientTotal `json:"clients,omitempty"`
}

type BandwidthClientTotal struct {
	Name     string `json:"name"`
	Download int64  `json:"download"`
	Upload   int64  `json:"upload"`
}

const (
	DASHBOARD_VERSION    = "3.3.0"
	LABOBOX_DIR          = "/opt/laboboxvpn"
	CLIENTS_DIR          = "/opt/laboboxvpn/clients"
	SEEDBOX_SCRIPT       = "/opt/laboboxvpn/laboboxvpn-manager.sh"
	CONFIG_FILE          = "/opt/laboboxvpn/utils/dashboard/config.json"
	TRACKERS_FILE        = "/opt/laboboxvpn/utils/dashboard/trackers.json"
	SUBSCRIPTIONS_FILE   = "/opt/laboboxvpn/utils/dashboard/subscriptions.json"
	BANDWIDTH_STATS_FILE = "/opt/laboboxvpn/utils/dashboard/bandwidth-stats.json"
	SEEDBOX_CONF         = "/opt/laboboxvpn/laboboxvpn.conf"
	NAS_MOUNT            = "/mnt/nas"
	DISCORD_ADMIN_URL    = "https://discord.com/users/clusmi"
	DEFAULT_LIVE_INTERVAL = 500
	DATA_INTERVAL         = 5 * time.Second
	ACTION_TIMEOUT        = 120 * time.Second
	SESSION_COOKIE_NAME   = "labobox_session"
	SESSION_DURATION      = 24 * time.Hour
	MAX_LOGIN_ATTEMPTS    = 5
	LOCKOUT_DURATION      = 15 * time.Minute
	FILEBOT_API_URL       = "http://127.0.0.1:5000"
)

var (
	dashboardPort = "8888"
	adminUser     = "clusmi"
	liveEnabled   = false
	liveInterval  = DEFAULT_LIVE_INTERVAL
	domain        = "inseedious.ovh"
	sftpPort      = "22"
)

type AuthUser struct {
	Role       string `json:"role"`
	ClientName string `json:"client_name"`
}

type Session struct {
	Token     string
	User      AuthUser
	ExpiresAt time.Time
}

type LoginAttempt struct {
	Count    int
	FirstTry time.Time
	LockedAt time.Time
	IsLocked bool
}

var (
	sessions        = make(map[string]*Session)
	sessionsMu      sync.RWMutex
	loginAttempts   = make(map[string]*LoginAttempt)
	loginMu         sync.RWMutex
	subscriptionsMu sync.RWMutex
)

func generateSessionToken() string {
	bytes := make([]byte, 32)
	rand.Read(bytes)
	return hex.EncodeToString(bytes)
}

func getClientPassword(clientName string) string {
	infoPath := filepath.Join(CLIENTS_DIR, clientName, "info.txt")
	file, err := os.Open(infoPath)
	if err != nil {
		return ""
	}
	defer file.Close()
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, "PASSWORD:") {
			return strings.TrimSpace(strings.TrimPrefix(line, "PASSWORD:"))
		}
	}
	return ""
}

func clientExists(clientName string) bool {
	infoPath := filepath.Join(CLIENTS_DIR, clientName, "info.txt")
	_, err := os.Stat(infoPath)
	return err == nil
}

func authenticate(username, password string) *AuthUser {
	if !clientExists(username) {
		return nil
	}
	clientPass := getClientPassword(username)
	if clientPass == "" || clientPass != password {
		return nil
	}
	role := "client"
	if username == adminUser {
		role = "admin"
	}
	return &AuthUser{Role: role, ClientName: username}
}

func createSession(user *AuthUser) string {
	token := generateSessionToken()
	sessionsMu.Lock()
	sessions[token] = &Session{Token: token, User: *user, ExpiresAt: time.Now().Add(SESSION_DURATION)}
	sessionsMu.Unlock()
	return token
}

func getSession(r *http.Request) *Session {
	cookie, err := r.Cookie(SESSION_COOKIE_NAME)
	if err != nil {
		return nil
	}
	sessionsMu.RLock()
	session, exists := sessions[cookie.Value]
	sessionsMu.RUnlock()
	if !exists || time.Now().After(session.ExpiresAt) {
		if exists {
			sessionsMu.Lock()
			delete(sessions, cookie.Value)
			sessionsMu.Unlock()
		}
		return nil
	}
	return session
}

func destroySession(w http.ResponseWriter, r *http.Request) {
	cookie, err := r.Cookie(SESSION_COOKIE_NAME)
	if err == nil {
		sessionsMu.Lock()
		delete(sessions, cookie.Value)
		sessionsMu.Unlock()
	}
	http.SetCookie(w, &http.Cookie{Name: SESSION_COOKIE_NAME, Value: "", Path: "/", MaxAge: -1, HttpOnly: true})
}

func cleanExpiredSessions() {
	sessionsMu.Lock()
	defer sessionsMu.Unlock()
	now := time.Now()
	for token, session := range sessions {
		if now.After(session.ExpiresAt) {
			delete(sessions, token)
		}
	}
}

func getClientIP(r *http.Request) string {
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		return strings.TrimSpace(strings.Split(xff, ",")[0])
	}
	if xri := r.Header.Get("X-Real-IP"); xri != "" {
		return xri
	}
	ip := r.RemoteAddr
	if idx := strings.LastIndex(ip, ":"); idx != -1 {
		ip = ip[:idx]
	}
	return ip
}

func isIPLocked(ip string) (bool, time.Duration) {
	loginMu.RLock()
	defer loginMu.RUnlock()
	attempt, exists := loginAttempts[ip]
	if !exists {
		return false, 0
	}
	if attempt.IsLocked {
		remaining := LOCKOUT_DURATION - time.Since(attempt.LockedAt)
		if remaining > 0 {
			return true, remaining
		}
	}
	return false, 0
}

func recordFailedLogin(ip string) (int, bool) {
	loginMu.Lock()
	defer loginMu.Unlock()
	attempt, exists := loginAttempts[ip]
	if !exists {
		loginAttempts[ip] = &LoginAttempt{Count: 1, FirstTry: time.Now()}
		return 1, false
	}
	if attempt.IsLocked && time.Since(attempt.LockedAt) >= LOCKOUT_DURATION {
		attempt.Count = 1
		attempt.FirstTry = time.Now()
		attempt.IsLocked = false
		attempt.LockedAt = time.Time{}
		return 1, false
	}
	attempt.Count++
	if attempt.Count >= MAX_LOGIN_ATTEMPTS {
		attempt.IsLocked = true
		attempt.LockedAt = time.Now()
		return attempt.Count, true
	}
	return attempt.Count, false
}

func resetLoginAttempts(ip string) {
	loginMu.Lock()
	defer loginMu.Unlock()
	delete(loginAttempts, ip)
}

func cleanOldLoginAttempts() {
	loginMu.Lock()
	defer loginMu.Unlock()
	now := time.Now()
	for ip, attempt := range loginAttempts {
		if !attempt.IsLocked && now.Sub(attempt.FirstTry) > time.Hour {
			delete(loginAttempts, ip)
		}
		if attempt.IsLocked && now.Sub(attempt.LockedAt) > LOCKOUT_DURATION+time.Hour {
			delete(loginAttempts, ip)
		}
	}
}

type Client struct {
	Name           string            `json:"name"`
	Status         string            `json:"status"`
	GluetunStatus  string            `json:"gluetun_status"`
	RtorrentStatus string            `json:"rtorrent_status"`
	VPNIP          string            `json:"vpn_ip"`
	PortWebUI      string            `json:"port_webui"`
	PortRT         string            `json:"port_rt"`
	Uptime         string            `json:"uptime"`
	QuotaUsed      int64             `json:"quota_used"`
	QuotaTotal     int64             `json:"quota_total"`
	QuotaPercent   float64           `json:"quota_percent"`
	Password       string            `json:"password,omitempty"`
	Subscription   *SubscriptionInfo `json:"subscription,omitempty"`
}

type App struct {
	Name      string `json:"name"`
	Container string `json:"container"`
	Status    string `json:"status"`
	Port      string `json:"port"`
	Uptime    string `json:"uptime"`
	WebURL    string `json:"web_url"`
	HasWebUI  bool   `json:"has_web_ui"`
}

type SystemStats struct {
	Hostname      string  `json:"hostname"`
	Uptime        string  `json:"uptime"`
	LoadAvg       string  `json:"load_avg"`
	CPUPercent    float64 `json:"cpu_percent"`
	CPUCount      int     `json:"cpu_count"`
	MemoryUsed    int64   `json:"memory_used"`
	MemoryTotal   int64   `json:"memory_total"`
	MemoryPercent float64 `json:"memory_percent"`
	// Disque système de la VM (/).
	DiskUsed    int64   `json:"disk_used"`
	DiskTotal   int64   `json:"disk_total"`
	DiskPercent float64 `json:"disk_percent"`
	// Espace HDD : NAS Synology monté sur /mnt/nas.
	NASUsed    int64   `json:"nas_used"`
	NASTotal   int64   `json:"nas_total"`
	NASPercent float64 `json:"nas_percent"`
	NASOnline  bool    `json:"nas_online"`
	// Espace SSD : disque temporaire (TEMP_DIR de laboboxvpn.conf).
	SSDUsed       int64   `json:"ssd_used"`
	SSDTotal      int64   `json:"ssd_total"`
	SSDPercent    float64 `json:"ssd_percent"`
	SSDConfigured bool    `json:"ssd_configured"`
	// Débit lecture/écriture par disque (octets/s), moyenné sur l'intervalle du
	// collecteur. VM/SSD via /proc/diskstats ; NAS via /proc/self/mountstats (NFS).
	VMReadBps   int64 `json:"vm_read_bps"`
	VMWriteBps  int64 `json:"vm_write_bps"`
	SSDReadBps  int64 `json:"ssd_read_bps"`
	SSDWriteBps int64 `json:"ssd_write_bps"`
	NASReadBps  int64 `json:"nas_read_bps"`
	NASWriteBps int64 `json:"nas_write_bps"`
}

type LiveStats struct {
	Download   int64  `json:"download"`
	Upload     int64  `json:"upload"`
	LastUpdate string `json:"last_update"`
}

type DashboardData struct {
	Clients         []Client    `json:"clients"`
	Apps            []App       `json:"apps"`
	Trackers        []Tracker   `json:"trackers"`
	System          SystemStats `json:"system"`
	Live            LiveStats   `json:"live"`
	LastUpdate      string      `json:"last_update"`
	Version         string      `json:"version"`
	LiveEnabled     bool        `json:"live_enabled"`
	LiveInterval    int         `json:"live_interval"`
	User            AuthUser    `json:"user"`
	IsAdmin         bool        `json:"is_admin"`
	ViewAsClient    bool        `json:"view_as_client"`
	Domain          string      `json:"domain"`
	SFTPPort        string      `json:"sftp_port"`
	DiscordAdminURL string      `json:"discord_admin_url"`
}

type ActionRequest struct {
	Action string            `json:"action"`
	Target string            `json:"target"`
	Params map[string]string `json:"params"`
}

type ActionResponse struct {
	Success bool   `json:"success"`
	Message string `json:"message"`
	Output  string `json:"output"`
}

//go:embed templates/*
var templatesFS embed.FS

var (
	cachedData   DashboardData
	cachedDataMu sync.RWMutex
	cachedLive   LiveStats
	cachedLiveMu sync.RWMutex
)

func loadConfig() error {
	configPaths := []string{CONFIG_FILE, "./config.json", filepath.Join(filepath.Dir(os.Args[0]), "config.json")}
	var configPath string
	for _, path := range configPaths {
		if _, err := os.Stat(path); err == nil {
			configPath = path
			break
		}
	}
	if configPath == "" {
		return nil
	}
	data, err := os.ReadFile(configPath)
	if err != nil {
		return fmt.Errorf("erreur lecture config: %v", err)
	}
	var config Config
	if err := json.Unmarshal(data, &config); err != nil {
		return fmt.Errorf("erreur parsing config: %v", err)
	}
	if config.Port != "" {
		dashboardPort = config.Port
	}
	if config.AdminUser != "" {
		adminUser = config.AdminUser
	}
	if config.LiveEnabled != nil {
		liveEnabled = *config.LiveEnabled
	}
	if config.LiveInterval != nil && *config.LiveInterval >= 100 {
		liveInterval = *config.LiveInterval
	}
	if config.Domain != "" {
		domain = config.Domain
	}
	if config.SFTPPort != "" {
		sftpPort = config.SFTPPort
	}
	log.Printf("Configuration chargée depuis %s", configPath)
	return nil
}

func loadTrackers() []Tracker {
	var trackers []Tracker
	data, err := os.ReadFile(TRACKERS_FILE)
	if err != nil {
		return trackers
	}
	json.Unmarshal(data, &trackers)
	return trackers
}

func loadSubscriptions() SubscriptionsData {
	subscriptionsMu.RLock()
	defer subscriptionsMu.RUnlock()
	data := make(SubscriptionsData)
	file, err := os.ReadFile(SUBSCRIPTIONS_FILE)
	if err != nil {
		return data
	}
	json.Unmarshal(file, &data)
	return data
}

func saveSubscriptions(data SubscriptionsData) error {
	subscriptionsMu.Lock()
	defer subscriptionsMu.Unlock()
	jsonData, err := json.MarshalIndent(data, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(SUBSCRIPTIONS_FILE, jsonData, 0644)
}

func formatDateFR(dateStr string) string {
	months := []string{"", "janv.", "févr.", "mars", "avr.", "mai", "juin", "juil.", "août", "sept.", "oct.", "nov.", "déc."}
	parts := strings.Split(dateStr, "-")
	if len(parts) != 3 {
		return dateStr
	}
	day, _ := strconv.Atoi(parts[2])
	month, _ := strconv.Atoi(parts[1])
	if month < 1 || month > 12 {
		return dateStr
	}
	return fmt.Sprintf("%d %s %s", day, months[month], parts[0])
}

func getSubscriptionInfo(clientName string) *SubscriptionInfo {
	subs := loadSubscriptions()
	sub, exists := subs[clientName]
	if !exists {
		return nil
	}
	dueDate, err := time.Parse("2006-01-02", sub.DueDate)
	if err != nil {
		return nil
	}
	now := time.Now().Truncate(24 * time.Hour)
	dueDate = dueDate.Truncate(24 * time.Hour)
	daysRemaining := int(dueDate.Sub(now).Hours() / 24)
	status := "ok"
	if sub.Suspended {
		status = "suspended"
	} else if daysRemaining <= 0 {
		status = "due-today"
	} else if daysRemaining <= 1 {
		status = "warning-1"
	} else if daysRemaining <= 3 {
		status = "warning-3"
	} else if daysRemaining <= 5 {
		status = "warning-5"
	}
	return &SubscriptionInfo{
		DueDate:       sub.DueDate,
		DueDateFR:     formatDateFR(sub.DueDate),
		DaysRemaining: daysRemaining,
		Suspended:     sub.Suspended,
		Status:        status,
		History:       sub.History,
	}
}

// suspendMarkerPath : marqueur de suspension d'un client (Option B). Sa présence
// indique au script (commandes « démarrer/redémarrer tous ») d'ignorer ce client
// tant qu'il n'a pas payé.
func suspendMarkerPath(clientName string) string {
	return filepath.Join(CLIENTS_DIR, clientName, ".suspended")
}

// startClientContainers relance la seedbox d'un client : gluetun d'abord, puis
// rtorrent (qui partage le namespace réseau de gluetun). Best-effort — les
// erreurs sont journalisées sans interrompre l'appelant.
func startClientContainers(clientName string) {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	if out, err := exec.CommandContext(ctx, "docker", "start", "gluetun-"+clientName).CombinedOutput(); err != nil {
		log.Printf("[SUBSCRIPTIONS] Démarrage gluetun-%s: %v (%s)", clientName, err, strings.TrimSpace(string(out)))
		return
	}
	// Laisser le namespace réseau de gluetun s'établir avant rtorrent.
	time.Sleep(3 * time.Second)
	if out, err := exec.CommandContext(ctx, "docker", "start", "rtorrent-"+clientName).CombinedOutput(); err != nil {
		log.Printf("[SUBSCRIPTIONS] Démarrage rtorrent-%s: %v (%s)", clientName, err, strings.TrimSpace(string(out)))
	}
}

func markClientPaid(clientName string, amount float64, dueDate string, method string, note string) error {
	subs := loadSubscriptions()
	if subs[clientName] == nil {
		subs[clientName] = &Subscription{History: []PaymentHistory{}}
	}
	subs[clientName].DueDate = dueDate
	subs[clientName].Suspended = false
	payment := PaymentHistory{Date: time.Now().Format("2006-01-02"), Amount: amount, Method: method, Note: note}
	subs[clientName].History = append([]PaymentHistory{payment}, subs[clientName].History...)
	if err := saveSubscriptions(subs); err != nil {
		return err
	}
	// Option B : lever le marqueur de suspension puis redémarrer automatiquement
	// la seedbox du client (gluetun + rtorrent).
	if err := os.Remove(suspendMarkerPath(clientName)); err != nil && !os.IsNotExist(err) {
		log.Printf("[SUBSCRIPTIONS] Retrait du marqueur de %s: %v", clientName, err)
	}
	go startClientContainers(clientName)
	return nil
}

func updateSubscriptionDate(clientName string, dueDate string) error {
	subs := loadSubscriptions()
	if subs[clientName] == nil {
		subs[clientName] = &Subscription{History: []PaymentHistory{}}
	}
	subs[clientName].DueDate = dueDate
	return saveSubscriptions(subs)
}

func suspendClient(clientName string) error {
	log.Printf("[SUBSCRIPTIONS] Suspension de %s pour non-paiement", clientName)
	subs := loadSubscriptions()
	if subs[clientName] != nil {
		subs[clientName].Suspended = true
		saveSubscriptions(subs)
	}
	// Option B : poser le marqueur respecté par le script (les commandes
	// « démarrer/redémarrer tous » sauteront ce client tant qu'il est suspendu).
	if err := os.WriteFile(suspendMarkerPath(clientName), []byte(time.Now().Format(time.RFC3339)+"\n"), 0644); err != nil {
		log.Printf("[SUBSCRIPTIONS] Écriture du marqueur de %s: %v", clientName, err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	exec.CommandContext(ctx, "docker", "stop", "gluetun-"+clientName).Run()
	exec.CommandContext(ctx, "docker", "stop", "rtorrent-"+clientName).Run()
	log.Printf("[SUBSCRIPTIONS] Client %s suspendu", clientName)
	return nil
}

func startSubscriptionChecker() {
	go func() {
		for {
			now := time.Now()
			nextMidnight := time.Date(now.Year(), now.Month(), now.Day()+1, 0, 0, 0, 0, now.Location())
			duration := nextMidnight.Sub(now)
			log.Printf("[SUBSCRIPTIONS] Prochaine vérification dans %v", duration)
			time.Sleep(duration)
			checkExpiredSubscriptions()
		}
	}()
}

func checkExpiredSubscriptions() {
	log.Printf("[SUBSCRIPTIONS] Vérification des abonnements expirés...")
	subs := loadSubscriptions()
	today := time.Now().Format("2006-01-02")
	for clientName, sub := range subs {
		if sub.Suspended {
			continue
		}
		if sub.DueDate < today {
			log.Printf("[SUBSCRIPTIONS] Abonnement expiré pour %s (échéance: %s)", clientName, sub.DueDate)
			suspendClient(clientName)
		}
	}
}

var (
	prevNetBytes struct {
		rx, tx    int64
		timestamp time.Time
	}
	prevNetMu sync.Mutex
)

func readNetBytes() (rx, tx int64) {
	data, _ := os.ReadFile("/proc/net/dev")
	lines := strings.Split(string(data), "\n")
	for _, line := range lines[2:] {
		fields := strings.Fields(line)
		if len(fields) < 10 {
			continue
		}
		iface := strings.TrimSuffix(fields[0], ":")
		if iface == "lo" {
			continue
		}
		r, _ := strconv.ParseInt(fields[1], 10, 64)
		t, _ := strconv.ParseInt(fields[9], 10, 64)
		rx += r
		tx += t
	}
	return
}

func startLiveCollector() {
	if !liveEnabled {
		return
	}
	prevNetMu.Lock()
	prevNetBytes.rx, prevNetBytes.tx = readNetBytes()
	prevNetBytes.timestamp = time.Now()
	prevNetMu.Unlock()
	go func() {
		ticker := time.NewTicker(time.Duration(liveInterval) * time.Millisecond)
		defer ticker.Stop()
		for range ticker.C {
			rx, tx := readNetBytes()
			now := time.Now()
			prevNetMu.Lock()
			elapsed := now.Sub(prevNetBytes.timestamp).Seconds()
			var downloadRate, uploadRate int64
			if elapsed > 0 && prevNetBytes.timestamp.Unix() > 0 {
				downloadRate = int64(float64(rx-prevNetBytes.rx) / elapsed)
				uploadRate = int64(float64(tx-prevNetBytes.tx) / elapsed)
				if downloadRate < 0 {
					downloadRate = 0
				}
				if uploadRate < 0 {
					uploadRate = 0
				}
			}
			prevNetBytes.rx, prevNetBytes.tx, prevNetBytes.timestamp = rx, tx, now
			prevNetMu.Unlock()
			cachedLiveMu.Lock()
			cachedLive = LiveStats{Download: downloadRate, Upload: uploadRate, LastUpdate: now.Format("15:04:05")}
			cachedLiveMu.Unlock()
		}
	}()
}

func startDataCollector() {
	collectAndCache()
	go func() {
		ticker := time.NewTicker(DATA_INTERVAL)
		defer ticker.Stop()
		for range ticker.C {
			collectAndCache()
		}
	}()
	go func() {
		ticker := time.NewTicker(1 * time.Hour)
		defer ticker.Stop()
		for range ticker.C {
			cleanExpiredSessions()
			cleanOldLoginAttempts()
		}
	}()
}

func collectAndCache() {
	data := DashboardData{
		Clients:         collectClients(),
		Apps:            collectApps(),
		Trackers:        loadTrackers(),
		System:          collectSystem(),
		LastUpdate:      time.Now().Format("15:04:05"),
		Version:         DASHBOARD_VERSION,
		LiveEnabled:     liveEnabled,
		LiveInterval:    liveInterval,
		Domain:          domain,
		SFTPPort:        sftpPort,
		DiscordAdminURL: DISCORD_ADMIN_URL,
	}
	cachedDataMu.Lock()
	cachedData = data
	cachedDataMu.Unlock()
}

func collectClients() []Client {
	var clients []Client
	entries, err := os.ReadDir(CLIENTS_DIR)
	if err != nil {
		return clients
	}
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		clientName := entry.Name()
		infoPath := filepath.Join(CLIENTS_DIR, clientName, "info.txt")
		if _, err := os.Stat(infoPath); os.IsNotExist(err) {
			continue
		}
		client := Client{Name: clientName, Status: "stopped", PortWebUI: "-", PortRT: "-"}
		if file, err := os.Open(infoPath); err == nil {
			scanner := bufio.NewScanner(file)
			for scanner.Scan() {
				parts := strings.SplitN(scanner.Text(), ":", 2)
				if len(parts) != 2 {
					continue
				}
				key, value := strings.TrimSpace(parts[0]), strings.TrimSpace(parts[1])
				switch key {
				case "PORT_RUTORRENT_WEBUI":
					client.PortWebUI = value
				case "PORT_RTORRENT_VPN":
					client.PortRT = value
				case "PASSWORD":
					client.Password = value
				}
			}
			file.Close()
		}
		client.GluetunStatus = getContainerStatus("gluetun-" + clientName)
		client.RtorrentStatus = getContainerStatus("rtorrent-" + clientName)
		if client.GluetunStatus == "running" && client.RtorrentStatus == "running" {
			client.Status = "running"
		} else if client.GluetunStatus == "running" || client.RtorrentStatus == "running" {
			client.Status = "partial"
		}
		if client.Status == "running" {
			client.Uptime = getContainerUptime("gluetun-" + clientName)
		}
		if client.GluetunStatus == "running" {
			client.VPNIP = getVPNIP(clientName)
		}
		nasPath := filepath.Join(NAS_MOUNT, "SEEDBOX_"+strings.ToUpper(clientName))
		client.QuotaUsed, client.QuotaTotal, client.QuotaPercent = getDiskUsage(nasPath)
		client.Subscription = getSubscriptionInfo(clientName)
		clients = append(clients, client)
	}
	sort.Slice(clients, func(i, j int) bool {
		pi, _ := strconv.Atoi(clients[i].PortWebUI)
		pj, _ := strconv.Atoi(clients[j].PortWebUI)
		return pi < pj
	})
	return clients
}

func getContainerStatus(name string) string {
	cmd := exec.Command("docker", "inspect", "-f", "{{.State.Status}}", name)
	output, err := cmd.Output()
	if err != nil {
		return "not_installed"
	}
	switch strings.TrimSpace(string(output)) {
	case "running":
		return "running"
	case "exited", "dead", "paused", "created":
		return "stopped"
	}
	return "not_installed"
}

func getContainerUptime(name string) string {
	cmd := exec.Command("docker", "inspect", "-f", "{{.State.StartedAt}}", name)
	output, err := cmd.Output()
	if err != nil {
		return "-"
	}
	startedAt, err := time.Parse(time.RFC3339Nano, strings.TrimSpace(string(output)))
	if err != nil {
		return "-"
	}
	duration := time.Since(startedAt)
	if duration.Hours() >= 24 {
		return fmt.Sprintf("%dj %dh", int(duration.Hours()/24), int(duration.Hours())%24)
	} else if duration.Hours() >= 1 {
		return fmt.Sprintf("%dh %dm", int(duration.Hours()), int(duration.Minutes())%60)
	}
	return fmt.Sprintf("%dm", int(duration.Minutes()))
}

func getVPNIP(clientName string) string {
	cmd := exec.Command("docker", "exec", "gluetun-"+clientName, "wget", "-qO-", "--timeout=5", "icanhazip.com")
	output, err := cmd.Output()
	if err != nil {
		cmd = exec.Command("docker", "exec", "gluetun-"+clientName, "wget", "-qO-", "--timeout=5", "api.ipify.org")
		output, err = cmd.Output()
		if err != nil {
			return "-"
		}
	}
	ip := strings.TrimSpace(string(output))
	if ip == "" || len(ip) > 45 {
		return "-"
	}
	return ip
}

func getDiskUsage(path string) (used, total int64, percent float64) {
	cmd := exec.Command("df", "-B1", path)
	output, err := cmd.Output()
	if err != nil {
		return 0, 1024 * 1024 * 1024 * 1024, 0
	}
	lines := strings.Split(string(output), "\n")
	if len(lines) < 2 {
		return 0, 1024 * 1024 * 1024 * 1024, 0
	}
	fields := strings.Fields(lines[1])
	if len(fields) < 4 {
		return 0, 1024 * 1024 * 1024 * 1024, 0
	}
	total, _ = strconv.ParseInt(fields[1], 10, 64)
	used, _ = strconv.ParseInt(fields[2], 10, 64)
	if total > 0 {
		percent = float64(used) / float64(total) * 100
	}
	return
}

func collectApps() []App {
	apps := []App{
		{Name: "Plex", Container: "plex", Port: "32400", WebURL: "https://plex." + domain, HasWebUI: true},
		{Name: "Jellyfin", Container: "jellyfin", Port: "8096", WebURL: "https://jellyfin." + domain, HasWebUI: true},
		{Name: "Resilio Sync", Container: "resilio", Port: "8888", WebURL: "https://resilio." + domain, HasWebUI: true},
		{Name: "Watchtower", Container: "watchtower", Port: "-", WebURL: "", HasWebUI: false},
	}
	for i := range apps {
		apps[i].Status = getContainerStatus(apps[i].Container)
		if apps[i].Status == "running" {
			apps[i].Uptime = getContainerUptime(apps[i].Container)
		}
	}
	return apps
}

func collectSystem() SystemStats {
	stats := SystemStats{}
	stats.Hostname, _ = os.Hostname()
	if data, err := os.ReadFile("/proc/uptime"); err == nil {
		fields := strings.Fields(string(data))
		if len(fields) > 0 {
			if seconds, err := strconv.ParseFloat(fields[0], 64); err == nil {
				days := int(seconds / 86400)
				hours := int(seconds/3600) % 24
				mins := int(seconds/60) % 60
				if days > 0 {
					stats.Uptime = fmt.Sprintf("%dj %dh %dm", days, hours, mins)
				} else {
					stats.Uptime = fmt.Sprintf("%dh %dm", hours, mins)
				}
			}
		}
	}
	if data, err := os.ReadFile("/proc/loadavg"); err == nil {
		fields := strings.Fields(string(data))
		if len(fields) >= 3 {
			stats.LoadAvg = strings.Join(fields[:3], " ")
		}
	}
	// CPU : deux échantillons de /proc/stat espacés de 200 ms (le delta busy/total
	// donne l'occupation instantanée). Ce collecteur tourne en tâche de fond
	// (toutes les DATA_INTERVAL), la pause ne bloque donc aucune requête.
	stats.CPUCount = runtime.NumCPU()
	idle0, total0 := readCPUStat()
	time.Sleep(200 * time.Millisecond)
	idle1, total1 := readCPUStat()
	if total1 > total0 {
		dTotal := float64(total1 - total0)
		dIdle := float64(idle1 - idle0)
		stats.CPUPercent = (dTotal - dIdle) / dTotal * 100
		if stats.CPUPercent < 0 {
			stats.CPUPercent = 0
		}
	}
	if data, err := os.ReadFile("/proc/meminfo"); err == nil {
		var memTotal, memAvailable int64
		for _, line := range strings.Split(string(data), "\n") {
			if strings.HasPrefix(line, "MemTotal:") {
				fmt.Sscanf(line, "MemTotal: %d kB", &memTotal)
				memTotal *= 1024
			} else if strings.HasPrefix(line, "MemAvailable:") {
				fmt.Sscanf(line, "MemAvailable: %d kB", &memAvailable)
				memAvailable *= 1024
			}
		}
		stats.MemoryTotal = memTotal
		stats.MemoryUsed = memTotal - memAvailable
		if memTotal > 0 {
			stats.MemoryPercent = float64(stats.MemoryUsed) / float64(memTotal) * 100
		}
	}
	now := time.Now()
	// Espace VM : disque système (/) + débit I/O (local, /proc/diskstats).
	if used, total, pct, ok := dfStats("/"); ok {
		stats.DiskUsed, stats.DiskTotal, stats.DiskPercent = used, total, pct
	}
	if dev := deviceForPath("/"); dev != "" {
		if r, w, ok := readDiskstats(dev); ok {
			stats.VMReadBps, stats.VMWriteBps = ioRate("dev:"+dev, r, w, now)
		}
	}
	// Espace HDD : le NAS est monté par client sous /mnt/nas/<X> (il n'y a pas de
	// point de montage unique sur /mnt/nas). On agrège les partages clients.
	if used, total, online := collectNAS(); online {
		stats.NASUsed, stats.NASTotal, stats.NASOnline = used, total, true
		if total > 0 {
			stats.NASPercent = float64(used) / float64(total) * 100
		}
		// Débit NFS (côté serveur) agrégé depuis /proc/self/mountstats.
		if r, w, ok := readNFSBytes(); ok {
			stats.NASReadBps, stats.NASWriteBps = ioRate("nas", r, w, now)
		}
	}
	// Espace SSD : disque temporaire TEMP_DIR (laboboxvpn.conf) s'il est configuré.
	if tempDir := readTempDir(); tempDir != "" {
		stats.SSDConfigured = true
		if used, total, pct, ok := dfStats(tempDir); ok {
			stats.SSDUsed, stats.SSDTotal, stats.SSDPercent = used, total, pct
		}
		if dev := deviceForPath(tempDir); dev != "" {
			if r, w, ok := readDiskstats(dev); ok {
				stats.SSDReadBps, stats.SSDWriteBps = ioRate("dev:"+dev, r, w, now)
			}
		}
	}
	return stats
}

// readCPUStat lit la ligne agrégée « cpu » de /proc/stat et renvoie le temps
// inactif (idle+iowait) et le temps total, en jiffies.
func readCPUStat() (idle, total uint64) {
	data, err := os.ReadFile("/proc/stat")
	if err != nil {
		return
	}
	for _, line := range strings.Split(string(data), "\n") {
		if strings.HasPrefix(line, "cpu ") {
			for i, f := range strings.Fields(line)[1:] {
				v, _ := strconv.ParseUint(f, 10, 64)
				total += v
				if i == 3 || i == 4 { // idle, iowait
					idle += v
				}
			}
			return
		}
	}
	return
}

// dfStats renvoie l'espace utilisé/total (octets) et le pourcentage d'un point
// de montage via `df`. Un timeout court évite de bloquer le collecteur si un
// montage réseau (NAS NFS) est gelé.
func dfStats(path string) (used, total int64, pct float64, ok bool) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	output, err := exec.CommandContext(ctx, "df", "-B1", path).Output()
	if err != nil {
		return
	}
	lines := strings.Split(string(output), "\n")
	if len(lines) < 2 {
		return
	}
	fields := strings.Fields(lines[1])
	if len(fields) < 4 {
		return
	}
	total, _ = strconv.ParseInt(fields[1], 10, 64)
	used, _ = strconv.ParseInt(fields[2], 10, 64)
	if total > 0 {
		pct = float64(used) / float64(total) * 100
	}
	ok = true
	return
}

// collectNAS agrège l'espace des partages NAS montés par client sous
// /mnt/nas/<X> (il n'y a pas de point de montage unique sur /mnt/nas). On ne
// retient que les montages de premier niveau — les sous-montages /mnt/nas/<X>/data
// pointent sur les mêmes données et seraient comptés deux fois. Un seul `df`
// couvre tous les points, avec timeout, pour ne pas bloquer si un export gèle.
func collectNAS() (used, total int64, online bool) {
	data, err := os.ReadFile("/proc/mounts")
	if err != nil {
		return
	}
	prefix := NAS_MOUNT + "/"
	var mounts []string
	seen := map[string]bool{}
	for _, line := range strings.Split(string(data), "\n") {
		f := strings.Fields(line)
		if len(f) < 2 {
			continue
		}
		mp := f[1]
		if !strings.HasPrefix(mp, prefix) {
			continue
		}
		if rest := strings.TrimPrefix(mp, prefix); rest == "" || strings.Contains(rest, "/") {
			continue // sous-montage (ex. .../data) : ignoré
		}
		if !seen[mp] {
			seen[mp] = true
			mounts = append(mounts, mp)
		}
	}
	if len(mounts) == 0 {
		return
	}
	online = true // des partages sont montés (même si le df échoue ensuite)
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	args := append([]string{"-B1", "--output=used,size"}, mounts...)
	out, err := exec.CommandContext(ctx, "df", args...).Output()
	if err != nil {
		return
	}
	for _, line := range strings.Split(string(out), "\n") {
		f := strings.Fields(line)
		if len(f) != 2 {
			continue // en-tête « Used Size » et lignes vides
		}
		u, e1 := strconv.ParseInt(f[0], 10, 64)
		t, e2 := strconv.ParseInt(f[1], 10, 64)
		if e1 != nil || e2 != nil {
			continue
		}
		used += u
		total += t
	}
	return
}

// readTempDir extrait la valeur de TEMP_DIR (chemin du SSD temporaire) depuis la
// config du gestionnaire (laboboxvpn.conf). Vide = SSD non configuré.
func readTempDir() string {
	data, err := os.ReadFile(SEEDBOX_CONF)
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "TEMP_DIR=") {
			return strings.TrimSpace(strings.Trim(strings.TrimPrefix(line, "TEMP_DIR="), "\"'"))
		}
	}
	return ""
}

// ---- Débit disque (lecture/écriture) ----

type diskSample struct {
	read, write int64
	t           time.Time
}

var (
	diskIOMu   sync.Mutex
	prevDiskIO = map[string]diskSample{}
)

// ioRate calcule le débit (octets/s) lecture/écriture pour une clé donnée à
// partir de l'échantillon précédent. Premier appel ou compteur remis à zéro : 0.
func ioRate(key string, read, write int64, now time.Time) (rBps, wBps int64) {
	diskIOMu.Lock()
	defer diskIOMu.Unlock()
	prev, ok := prevDiskIO[key]
	prevDiskIO[key] = diskSample{read: read, write: write, t: now}
	if !ok {
		return 0, 0
	}
	elapsed := now.Sub(prev.t).Seconds()
	if elapsed <= 0 {
		return 0, 0
	}
	if read >= prev.read {
		rBps = int64(float64(read-prev.read) / elapsed)
	}
	if write >= prev.write {
		wBps = int64(float64(write-prev.write) / elapsed)
	}
	return
}

// deviceForPath renvoie le nom de périphérique bloc (tel qu'affiché dans
// /proc/diskstats, ex. « sda1 », « md0 ») du système de fichiers contenant
// `path`, via le point de montage le plus spécifique de /proc/mounts. Renvoie
// "" si ce n'est pas un périphérique /dev (ex. montage NFS).
func deviceForPath(path string) string {
	data, err := os.ReadFile("/proc/mounts")
	if err != nil {
		return ""
	}
	bestDev, bestLen := "", -1
	for _, line := range strings.Split(string(data), "\n") {
		f := strings.Fields(line)
		if len(f) < 2 || !strings.HasPrefix(f[0], "/dev/") {
			continue
		}
		mp := f[1]
		if path == mp || strings.HasPrefix(path, strings.TrimRight(mp, "/")+"/") {
			if len(mp) > bestLen {
				bestLen = len(mp)
				bestDev = strings.TrimPrefix(f[0], "/dev/")
			}
		}
	}
	return bestDev
}

// readDiskstats lit les octets cumulés lus/écrits d'un périphérique bloc dans
// /proc/diskstats (secteurs de 512 octets).
func readDiskstats(dev string) (readBytes, writeBytes int64, ok bool) {
	data, err := os.ReadFile("/proc/diskstats")
	if err != nil {
		return
	}
	for _, line := range strings.Split(string(data), "\n") {
		f := strings.Fields(line)
		if len(f) < 10 || f[2] != dev {
			continue
		}
		secR, _ := strconv.ParseInt(f[5], 10, 64) // secteurs lus
		secW, _ := strconv.ParseInt(f[9], 10, 64) // secteurs écrits
		return secR * 512, secW * 512, true
	}
	return
}

// readNFSBytes agrège les octets lus/écrits côté serveur NFS depuis
// /proc/self/mountstats, dédupliqués par export source (un même export monté
// plusieurs fois partage les mêmes compteurs).
func readNFSBytes() (readBytes, writeBytes int64, ok bool) {
	data, err := os.ReadFile("/proc/self/mountstats")
	if err != nil {
		return
	}
	seen := map[string]bool{}
	curSrc, curIsNFS := "", false
	for _, line := range strings.Split(string(data), "\n") {
		if strings.HasPrefix(line, "device ") {
			// "device <src> mounted on <mp> with fstype <fs> ..."
			f := strings.Fields(line)
			curSrc, curIsNFS = "", false
			if len(f) >= 8 {
				curSrc = f[1]
				for i := 4; i < len(f)-1; i++ {
					if f[i] == "fstype" {
						curIsNFS = f[i+1] == "nfs" || f[i+1] == "nfs4"
						break
					}
				}
			}
			continue
		}
		if !curIsNFS || seen[curSrc] {
			continue
		}
		if t := strings.TrimSpace(line); strings.HasPrefix(t, "bytes:") {
			nums := strings.Fields(strings.TrimPrefix(t, "bytes:"))
			if len(nums) >= 6 {
				sr, _ := strconv.ParseInt(nums[4], 10, 64) // octets lus depuis le serveur
				sw, _ := strconv.ParseInt(nums[5], 10, 64) // octets écrits vers le serveur
				readBytes += sr
				writeBytes += sw
				seen[curSrc] = true
				ok = true
			}
		}
	}
	return
}

var allowedActions = map[string]bool{
	"start": true, "stop": true, "restart": true, "remove": true,
	"health": true, "quota": true, "sync-libs": true, "mount": true, "build": true,
	"install-plex": true, "uninstall-plex": true,
	"install-jellyfin": true, "uninstall-jellyfin": true,
	"install-resilio": true, "uninstall-resilio": true,
	"install-watchtower": true, "uninstall-watchtower": true,
	"docker-start": true, "docker-stop": true, "docker-restart": true,
	"mark-paid": true, "update-subscription": true,
}

var adminOnlyActions = map[string]bool{
	"remove": true, "health": true, "quota": true, "sync-libs": true,
	"mount": true, "build": true,
	"install-plex": true, "uninstall-plex": true,
	"install-jellyfin": true, "uninstall-jellyfin": true,
	"install-resilio": true, "uninstall-resilio": true,
	"install-watchtower": true, "uninstall-watchtower": true,
	"docker-start": true, "docker-stop": true, "docker-restart": true,
	"mark-paid": true, "update-subscription": true,
}

func executeAction(req ActionRequest, user *AuthUser) ActionResponse {
	if !allowedActions[req.Action] {
		return ActionResponse{Success: false, Message: "Action non autorisée"}
	}
	if user.Role != "admin" {
		if adminOnlyActions[req.Action] {
			return ActionResponse{Success: false, Message: "Action réservée à l'administrateur"}
		}
		if req.Target != "" && req.Target != user.ClientName {
			return ActionResponse{Success: false, Message: "Vous ne pouvez agir que sur votre propre seedbox"}
		}
		subInfo := getSubscriptionInfo(user.ClientName)
		if subInfo != nil && subInfo.Suspended {
			return ActionResponse{Success: false, Message: "Votre abonnement a expiré. Contactez l'administrateur."}
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), ACTION_TIMEOUT)
	defer cancel()

	switch req.Action {
	case "mark-paid":
		if req.Target == "" {
			return ActionResponse{Success: false, Message: "Client requis"}
		}
		amount, _ := strconv.ParseFloat(req.Params["amount"], 64)
		if err := markClientPaid(req.Target, amount, req.Params["due_date"], req.Params["method"], req.Params["note"]); err != nil {
			return ActionResponse{Success: false, Message: fmt.Sprintf("Erreur: %v", err)}
		}
		return ActionResponse{Success: true, Message: fmt.Sprintf("Paiement enregistré pour %s — redémarrage de la seedbox en cours", req.Target)}
	case "update-subscription":
		if req.Target == "" {
			return ActionResponse{Success: false, Message: "Client requis"}
		}
		if err := updateSubscriptionDate(req.Target, req.Params["due_date"]); err != nil {
			return ActionResponse{Success: false, Message: fmt.Sprintf("Erreur: %v", err)}
		}
		return ActionResponse{Success: true, Message: fmt.Sprintf("Échéance mise à jour pour %s", req.Target)}
	}

	var cmd *exec.Cmd
	switch req.Action {
	case "docker-start":
		cmd = exec.CommandContext(ctx, "docker", "start", req.Target)
	case "docker-stop":
		cmd = exec.CommandContext(ctx, "docker", "stop", req.Target)
	case "docker-restart":
		cmd = exec.CommandContext(ctx, "docker", "restart", req.Target)
	default:
		var args []string
		switch req.Action {
		case "start", "stop", "restart", "remove":
			if req.Target == "" {
				return ActionResponse{Success: false, Message: "Cible requise"}
			}
			args = []string{req.Action, req.Target}
		default:
			args = []string{req.Action}
		}
		cmd = exec.CommandContext(ctx, SEEDBOX_SCRIPT, args...)
	}
	output, err := cmd.CombinedOutput()
	if ctx.Err() == context.DeadlineExceeded {
		return ActionResponse{Success: false, Message: "Timeout dépassé", Output: string(output)}
	}
	if err != nil {
		return ActionResponse{Success: false, Message: err.Error(), Output: string(output)}
	}
	return ActionResponse{Success: true, Message: "Action exécutée", Output: string(output)}
}

func formatBytes(bytes int64) string {
	const unit = 1024
	if bytes < unit {
		return fmt.Sprintf("%d o", bytes)
	}
	div, exp := int64(unit), 0
	for n := bytes / unit; n >= unit; n /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %cio", float64(bytes)/float64(div), "KMGTPE"[exp])
}

func formatSpeed(bytes int64) string {
	return formatBytes(bytes) + "/s"
}

func requireAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if getSession(r) == nil {
			http.Redirect(w, r, "/login", http.StatusFound)
			return
		}
		next(w, r)
	}
}

// ==================== FILEBOT FUNCTIONS ====================

func isFilebotInstalled() bool {
	cmd := exec.Command("docker", "inspect", "filebot")
	return cmd.Run() == nil
}

func isFilebotRunning() bool {
	cmd := exec.Command("docker", "inspect", "-f", "{{.State.Running}}", "filebot")
	output, err := cmd.Output()
	if err != nil {
		return false
	}
	return strings.TrimSpace(string(output)) == "true"
}

func handleFilebot(w http.ResponseWriter, r *http.Request) {
	session := getSession(r)
	if session == nil {
		http.Redirect(w, r, "/login", http.StatusFound)
		return
	}

	// Vérifier que FileBot est disponible
	if !isFilebotRunning() {
		http.Error(w, "FileBot n'est pas disponible", http.StatusServiceUnavailable)
		return
	}

	tmpl, err := template.ParseFS(templatesFS, "templates/filebot.html")
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	data := map[string]interface{}{
		"ClientName": session.User.ClientName,
		"IsAdmin":    session.User.Role == "admin",
		"Version":    DASHBOARD_VERSION,
	}

	tmpl.Execute(w, data)
}

func handleFilebotLogs(w http.ResponseWriter, r *http.Request) {
	session := getSession(r)
	if session == nil {
		http.Redirect(w, r, "/login", http.StatusFound)
		return
	}

	tmpl, err := template.ParseFS(templatesFS, "templates/filebot-logs.html")
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	data := map[string]interface{}{
		"ClientName": session.User.ClientName,
		"IsAdmin":    session.User.Role == "admin",
		"Version":    DASHBOARD_VERSION,
	}

	tmpl.Execute(w, data)
}

func handleFilebotAPI(w http.ResponseWriter, r *http.Request) {
	session := getSession(r)
	if session == nil {
		http.Error(w, "Non autorisé", http.StatusUnauthorized)
		return
	}

	// Construire l'URL de l'API FileBot
	apiPath := strings.TrimPrefix(r.URL.Path, "/api/filebot")
	targetURL := FILEBOT_API_URL + apiPath

	// Créer la requête vers l'API FileBot
	var req *http.Request
	var err error

	if r.Method == http.MethodPost {
		// Lire le body
		body, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, "Erreur lecture body", http.StatusBadRequest)
			return
		}
		defer r.Body.Close()

		// Parser le JSON pour injecter le client name
		var jsonData map[string]interface{}
		if len(body) > 0 {
			if err := json.Unmarshal(body, &jsonData); err != nil {
				http.Error(w, "JSON invalide", http.StatusBadRequest)
				return
			}
		} else {
			jsonData = make(map[string]interface{})
		}

		// Sécurité: forcer le client name pour les non-admin
		if session.User.Role != "admin" {
			jsonData["client"] = session.User.ClientName
		} else if jsonData["client"] == nil {
			jsonData["client"] = session.User.ClientName
		}

		// Re-sérialiser
		newBody, _ := json.Marshal(jsonData)
		req, err = http.NewRequest(r.Method, targetURL, bytes.NewReader(newBody))
		req.Header.Set("Content-Type", "application/json")
	} else {
		req, err = http.NewRequest(r.Method, targetURL, nil)
		// Ajouter le client en query param pour GET
		q := req.URL.Query()
		if session.User.Role != "admin" {
			q.Set("client", session.User.ClientName)
		} else if r.URL.Query().Get("client") == "" {
			q.Set("client", session.User.ClientName)
		} else {
			q.Set("client", r.URL.Query().Get("client"))
		}
		req.URL.RawQuery = q.Encode()
	}

	if err != nil {
		http.Error(w, "Erreur création requête", http.StatusInternalServerError)
		return
	}

	// Copier les headers pertinents
	for k, v := range r.Header {
		if k != "Cookie" && k != "Host" {
			req.Header[k] = v
		}
	}

	// Exécuter la requête
	client := &http.Client{Timeout: 5 * time.Minute}
	resp, err := client.Do(req)
	if err != nil {
		http.Error(w, "FileBot non disponible", http.StatusServiceUnavailable)
		return
	}
	defer resp.Body.Close()

	// Copier la réponse
	for k, v := range resp.Header {
		w.Header()[k] = v
	}
	w.WriteHeader(resp.StatusCode)
	io.Copy(w, resp.Body)
}

func handleFilebotStatus(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	status := map[string]interface{}{
		"installed": isFilebotInstalled(),
		"running":   isFilebotRunning(),
	}

	json.NewEncoder(w).Encode(status)
}

// ==================== END FILEBOT FUNCTIONS ====================

func handleLogin(w http.ResponseWriter, r *http.Request) {
	clientIP := getClientIP(r)
	if r.Method == http.MethodGet {
		locked, remaining := isIPLocked(clientIP)
		errorMsg := r.URL.Query().Get("error")
		if locked {
			errorMsg = fmt.Sprintf("Trop de tentatives. Réessayez dans %d minute(s)", int(remaining.Minutes())+1)
		}
		tmpl, _ := template.ParseFS(templatesFS, "templates/login.html")
		tmpl.Execute(w, map[string]interface{}{"Error": errorMsg, "Version": DASHBOARD_VERSION})
		return
	}
	if r.Method == http.MethodPost {
		if locked, remaining := isIPLocked(clientIP); locked {
			http.Redirect(w, r, fmt.Sprintf("/login?error=Trop+de+tentatives.+Réessayez+dans+%d+minute(s)", int(remaining.Minutes())+1), http.StatusFound)
			return
		}
		user := authenticate(r.FormValue("username"), r.FormValue("password"))
		if user == nil {
			attempts, nowLocked := recordFailedLogin(clientIP)
			if nowLocked {
				http.Redirect(w, r, "/login?error=Trop+de+tentatives.+Compte+bloqué+15+minutes", http.StatusFound)
			} else {
				remaining := MAX_LOGIN_ATTEMPTS - attempts
				if remaining <= 2 {
					http.Redirect(w, r, fmt.Sprintf("/login?error=Identifiants+incorrects.+%d+tentative(s)+restante(s)", remaining), http.StatusFound)
				} else {
					http.Redirect(w, r, "/login?error=Identifiants+incorrects", http.StatusFound)
				}
			}
			return
		}
		resetLoginAttempts(clientIP)
		token := createSession(user)
		isHTTPS := r.TLS != nil || r.Header.Get("X-Forwarded-Proto") == "https"
		http.SetCookie(w, &http.Cookie{
			Name: SESSION_COOKIE_NAME, Value: token, Path: "/",
			MaxAge: int(SESSION_DURATION.Seconds()), HttpOnly: true,
			Secure: isHTTPS, SameSite: http.SameSiteStrictMode,
		})
		http.Redirect(w, r, "/", http.StatusFound)
		return
	}
	http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
}

func handleLogout(w http.ResponseWriter, r *http.Request) {
	destroySession(w, r)
	http.Redirect(w, r, "/login", http.StatusFound)
}

func handleIndex(w http.ResponseWriter, r *http.Request) {
	session := getSession(r)
	if session == nil {
		http.Redirect(w, r, "/login", http.StatusFound)
		return
	}
	funcMap := template.FuncMap{
		"lower":       func(s string) string { return strings.ToLower(strings.ReplaceAll(s, " ", "-")) },
		"formatBytes": formatBytes,
		"formatSpeed": formatSpeed,
	}
	tmpl, err := template.New("index.html").Funcs(funcMap).ParseFS(templatesFS, "templates/index.html")
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	cachedDataMu.RLock()
	data := cachedData
	// Copie profonde des clients pour éviter de modifier le cache
	clientsCopy := make([]Client, len(data.Clients))
	copy(clientsCopy, data.Clients)
	data.Clients = clientsCopy
	cachedDataMu.RUnlock()
	cachedLiveMu.RLock()
	data.Live = cachedLive
	cachedLiveMu.RUnlock()
	data.User = session.User
	data.IsAdmin = session.User.Role == "admin"
	data.ViewAsClient = false

	// Vérifier si l'admin veut voir en mode client
	viewMode := r.URL.Query().Get("view")

	if !data.IsAdmin {
		// Utilisateur normal : filtrer pour ne voir que sa seedbox
		var filteredClients []Client
		for _, client := range data.Clients {
			if client.Name == session.User.ClientName {
				filteredClients = append(filteredClients, client)
				break
			}
		}
		data.Clients = filteredClients
	} else if viewMode == "client" {
		// Admin en mode vue client : montrer SA propre seedbox
		data.ViewAsClient = true
		// Chercher le client qui correspond à l'admin
		var clientFound *Client
		for i, client := range data.Clients {
			if client.Name == session.User.ClientName {
				clientFound = &data.Clients[i]
				break
			}
		}
		if clientFound != nil {
			clientFound.Password = getClientPassword(clientFound.Name)
			data.Clients = []Client{*clientFound}
		} else if len(data.Clients) > 0 {
			// Fallback sur le premier client si l'admin n'a pas de seedbox
			firstClient := data.Clients[0]
			firstClient.Password = getClientPassword(firstClient.Name)
			data.Clients = []Client{firstClient}
		}
	} else {
		// Admin en mode normal : masquer les mots de passe
		for i := range data.Clients {
			data.Clients[i].Password = ""
		}
	}
	tmpl.Execute(w, data)
}

func handleAPIData(w http.ResponseWriter, r *http.Request) {
	session := getSession(r)
	if session == nil {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	cachedDataMu.RLock()
	data := cachedData
	// Copie profonde des clients pour éviter de modifier le cache
	clientsCopy := make([]Client, len(data.Clients))
	copy(clientsCopy, data.Clients)
	data.Clients = clientsCopy
	cachedDataMu.RUnlock()
	cachedLiveMu.RLock()
	data.Live = cachedLive
	cachedLiveMu.RUnlock()
	data.User = session.User
	data.IsAdmin = session.User.Role == "admin"
	if !data.IsAdmin {
		var filteredClients []Client
		for _, client := range data.Clients {
			if client.Name == session.User.ClientName {
				filteredClients = append(filteredClients, client)
				break
			}
		}
		data.Clients = filteredClients
	} else {
		for i := range data.Clients {
			data.Clients[i].Password = ""
		}
	}
	json.NewEncoder(w).Encode(data)
}

func handleAPILive(w http.ResponseWriter, r *http.Request) {
	session := getSession(r)
	if session == nil {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	if session.User.Role != "admin" {
		json.NewEncoder(w).Encode(LiveStats{Download: 0, Upload: 0})
		return
	}
	cachedLiveMu.RLock()
	live := cachedLive
	cachedLiveMu.RUnlock()
	json.NewEncoder(w).Encode(live)
}

func handleAPIAction(w http.ResponseWriter, r *http.Request) {
	session := getSession(r)
	if session == nil {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}
	var req ActionRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	log.Printf("[%s] Action: %s, Target: %s", session.User.ClientName, req.Action, req.Target)
	response := executeAction(req, &session.User)
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(response)
}

func handleSubscriptionHistory(w http.ResponseWriter, r *http.Request) {
	session := getSession(r)
	if session == nil || session.User.Role != "admin" {
		http.Error(w, "Non autorisé", http.StatusForbidden)
		return
	}
	clientName := r.URL.Query().Get("client")
	if clientName == "" {
		http.Error(w, "Client requis", http.StatusBadRequest)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	subInfo := getSubscriptionInfo(clientName)
	if subInfo == nil {
		json.NewEncoder(w).Encode([]PaymentHistory{})
		return
	}
	json.NewEncoder(w).Encode(subInfo.History)
}

func handleAPIBandwidth(w http.ResponseWriter, r *http.Request) {
	session := getSession(r)
	if session == nil {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}

	// Agrégat colocation (admin) demandé explicitement via ?scope=all. Nécessaire
	// car l'admin est aussi un client : sinon clientName prendrait son propre nom
	// et l'agrégat ne serait jamais renvoyé (le widget « Top consommateurs »
	// n'aurait alors que les stats de l'admin, sans la liste des clients).
	if r.URL.Query().Get("scope") == "all" {
		if session.User.Role != "admin" {
			http.Error(w, "Non autorisé", http.StatusForbidden)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		var allStats map[string]BandwidthClientStats
		if data, err := os.ReadFile(BANDWIDTH_STATS_FILE); err == nil {
			json.Unmarshal(data, &allStats)
		}
		json.NewEncoder(w).Encode(aggregateBandwidth(allStats))
		return
	}

	clientName := r.URL.Query().Get("client")
	if clientName == "" {
		// Si pas de client spécifié, utiliser le nom de l'utilisateur connecté
		clientName = session.User.ClientName
	}

	// Vérifier que l'utilisateur a le droit d'accéder à ces stats
	if session.User.Role != "admin" && session.User.ClientName != clientName {
		http.Error(w, "Non autorisé", http.StatusForbidden)
		return
	}

	w.Header().Set("Content-Type", "application/json")

	// Lire le fichier de stats
	data, err := os.ReadFile(BANDWIDTH_STATS_FILE)
	if err != nil {
		// Fichier n'existe pas encore, retourner des valeurs vides
		json.NewEncoder(w).Encode(BandwidthResponse{
			Download:      0,
			Upload:        0,
			DownloadToday: 0,
			UploadToday:   0,
			Updated:       "",
			History:       []BandwidthHistory{},
		})
		return
	}

	var allStats map[string]BandwidthClientStats
	if err := json.Unmarshal(data, &allStats); err != nil {
		log.Printf("Erreur parsing bandwidth stats: %v", err)
		json.NewEncoder(w).Encode(BandwidthResponse{
			Download:      0,
			Upload:        0,
			DownloadToday: 0,
			UploadToday:   0,
			Updated:       "",
			History:       []BandwidthHistory{},
		})
		return
	}

	// Admin sans client précis -> agrégat de TOUS les clients (30 jours).
	if session.User.Role == "admin" && clientName == "" {
		json.NewEncoder(w).Encode(aggregateBandwidth(allStats))
		return
	}

	clientStats, exists := allStats[clientName]
	if !exists {
		json.NewEncoder(w).Encode(BandwidthResponse{
			Download:      0,
			Upload:        0,
			DownloadToday: 0,
			UploadToday:   0,
			Updated:       "",
			History:       []BandwidthHistory{},
		})
		return
	}

	// Total affiché = somme des 30 derniers jours (pas le compteur brut cumulatif).
	var totalDl, totalUl int64
	for _, h := range clientStats.History {
		totalDl += h.Download
		totalUl += h.Upload
	}

	response := BandwidthResponse{
		Download:      totalDl,
		Upload:        totalUl,
		DownloadToday: clientStats.TodayDelta["download"],
		UploadToday:   clientStats.TodayDelta["upload"],
		Updated:       clientStats.Updated,
		History:       clientStats.History,
	}

	json.NewEncoder(w).Encode(response)
}

// ==================== COLLECTE BANDE PASSANTE ====================
// Lit périodiquement les compteurs de l'interface VPN (wg0) de chaque client
// via /proc/<pid-gluetun>/net/dev — c'est le namespace réseau du conteneur, donc
// pas besoin de shell dans gluetun (qui n'en a pas). On accumule des totaux
// journaliers dans bandwidth-stats.json (30 jours glissants), en gérant les
// remises à zéro du compteur (redémarrage du conteneur/VPN).

var bandwidthMu sync.Mutex

func readVPNCounters(container string) (int64, int64, bool) {
	out, err := exec.Command("docker", "inspect", "-f", "{{.State.Pid}}", container).Output()
	if err != nil {
		return 0, 0, false
	}
	pid := strings.TrimSpace(string(out))
	if pid == "" || pid == "0" {
		return 0, 0, false
	}
	data, err := os.ReadFile("/proc/" + pid + "/net/dev")
	if err != nil {
		return 0, 0, false
	}
	// Interface tunnel : wg0 (WireGuard) en priorité, tun0 en repli.
	for _, want := range []string{"wg0", "tun0"} {
		for _, line := range strings.Split(string(data), "\n") {
			line = strings.TrimSpace(line)
			if !strings.HasPrefix(line, want+":") {
				continue
			}
			f := strings.Fields(strings.TrimPrefix(line, want+":"))
			// /proc/net/dev : rx = bytes packets errs drop fifo frame compressed
			// multicast (8 champs) ; puis tx = bytes ... -> rx=f[0], tx=f[8]
			if len(f) >= 9 {
				rx, _ := strconv.ParseInt(f[0], 10, 64)
				tx, _ := strconv.ParseInt(f[8], 10, 64)
				return rx, tx, true
			}
		}
	}
	return 0, 0, false
}

func pruneBandwidthHistory(h []BandwidthHistory, days int) []BandwidthHistory {
	cutoff := time.Now().AddDate(0, 0, -days).Format("2006-01-02")
	out := make([]BandwidthHistory, 0, len(h))
	for _, e := range h {
		if e.Date >= cutoff {
			out = append(out, e)
		}
	}
	return out
}

func collectBandwidthOnce() {
	entries, err := os.ReadDir(CLIENTS_DIR)
	if err != nil {
		return
	}
	bandwidthMu.Lock()
	defer bandwidthMu.Unlock()

	allStats := map[string]BandwidthClientStats{}
	if data, err := os.ReadFile(BANDWIDTH_STATS_FILE); err == nil {
		json.Unmarshal(data, &allStats)
	}

	today := time.Now().Format("2006-01-02")
	nowStr := time.Now().Format("2006-01-02 15:04:05")

	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		client := e.Name()
		if _, err := os.Stat(filepath.Join(CLIENTS_DIR, client, "info.txt")); err != nil {
			continue
		}
		rx, tx, ok := readVPNCounters("gluetun-" + client)
		if !ok {
			continue // conteneur arrêté / iface absente -> on garde l'historique tel quel
		}
		st := allStats[client]
		if st.Current == nil {
			st.Current = map[string]int64{}
		}
		if st.TodayDelta == nil {
			st.TodayDelta = map[string]int64{}
		}

		// Delta depuis la dernière lecture. Si le compteur a baissé, c'est un
		// redémarrage (remise à zéro) -> le delta est la nouvelle valeur.
		var dDl, dUl int64
		if last, ok := st.Current["download"]; ok {
			if rx >= last {
				dDl = rx - last
			} else {
				dDl = rx
			}
		}
		if last, ok := st.Current["upload"]; ok {
			if tx >= last {
				dUl = tx - last
			} else {
				dUl = tx
			}
		}

		if st.TodayDate != today {
			st.TodayDate = today
			st.TodayDelta = map[string]int64{"download": 0, "upload": 0}
		}
		st.TodayDelta["download"] += dDl
		st.TodayDelta["upload"] += dUl

		st.Current["download"] = rx
		st.Current["upload"] = tx
		st.Updated = nowStr

		found := false
		for i := range st.History {
			if st.History[i].Date == today {
				st.History[i].Download += dDl
				st.History[i].Upload += dUl
				found = true
				break
			}
		}
		if !found {
			st.History = append(st.History, BandwidthHistory{Date: today, Download: dDl, Upload: dUl})
		}
		st.History = pruneBandwidthHistory(st.History, 30)
		allStats[client] = st
	}

	// Écriture atomique (tmp + rename).
	if data, err := json.MarshalIndent(allStats, "", "  "); err == nil {
		tmp := BANDWIDTH_STATS_FILE + ".tmp"
		if os.WriteFile(tmp, data, 0644) == nil {
			os.Rename(tmp, BANDWIDTH_STATS_FILE)
		}
	}
}

func startBandwidthCollector() {
	go func() {
		collectBandwidthOnce()
		ticker := time.NewTicker(2 * time.Minute)
		defer ticker.Stop()
		for range ticker.C {
			collectBandwidthOnce()
		}
	}()
}

// aggregateBandwidth additionne l'historique de TOUS les clients (vue admin).
func aggregateBandwidth(all map[string]BandwidthClientStats) BandwidthResponse {
	byDate := map[string]*BandwidthHistory{}
	var totalDl, totalUl, todayDl, todayUl int64
	latest := ""
	clients := make([]BandwidthClientTotal, 0, len(all))
	for name, st := range all {
		todayDl += st.TodayDelta["download"]
		todayUl += st.TodayDelta["upload"]
		if st.Updated > latest {
			latest = st.Updated
		}
		var cDl, cUl int64
		for _, h := range st.History {
			cDl += h.Download
			cUl += h.Upload
			e, ok := byDate[h.Date]
			if !ok {
				e = &BandwidthHistory{Date: h.Date}
				byDate[h.Date] = e
			}
			e.Download += h.Download
			e.Upload += h.Upload
		}
		totalDl += cDl
		totalUl += cUl
		clients = append(clients, BandwidthClientTotal{Name: name, Download: cDl, Upload: cUl})
	}
	hist := make([]BandwidthHistory, 0, len(byDate))
	for _, e := range byDate {
		hist = append(hist, *e)
	}
	sort.Slice(hist, func(i, j int) bool { return hist[i].Date < hist[j].Date })
	// Classement décroissant par volume total (download + upload).
	sort.Slice(clients, func(i, j int) bool {
		return clients[i].Download+clients[i].Upload > clients[j].Download+clients[j].Upload
	})
	return BandwidthResponse{
		Download: totalDl, Upload: totalUl,
		DownloadToday: todayDl, UploadToday: todayUl,
		Updated: latest, History: hist, Clients: clients,
	}
}

func main() {
	loadConfig()
	fmt.Println("╔═══════════════════════════════════════════════════════════════╗")
	fmt.Printf("║  LaboBox Dashboard v%-38s║\n", DASHBOARD_VERSION)
	fmt.Println("╠═══════════════════════════════════════════════════════════════╣")
	fmt.Printf("║  Port      : %-45s║\n", dashboardPort)
	fmt.Printf("║  Admin     : %-45s║\n", adminUser)
	fmt.Printf("║  Live      : %-45v║\n", liveEnabled)
	fmt.Println("╚═══════════════════════════════════════════════════════════════╝")
	fmt.Println()

	log.Println("Démarrage du collecteur live...")
	startLiveCollector()
	log.Println("Démarrage du collecteur de données...")
	startDataCollector()
	log.Println("Démarrage du vérificateur d'abonnements...")
	startSubscriptionChecker()
	log.Println("Démarrage du collecteur de bande passante...")
	startBandwidthCollector()

	http.HandleFunc("/login", handleLogin)
	http.HandleFunc("/logout", handleLogout)
	http.HandleFunc("/", requireAuth(handleIndex))
	http.HandleFunc("/api/data", handleAPIData)
	http.HandleFunc("/api/live", handleAPILive)
	http.HandleFunc("/api/action", handleAPIAction)
	http.HandleFunc("/api/subscription/history", handleSubscriptionHistory)
	http.HandleFunc("/api/bandwidth", handleAPIBandwidth)

	// Routes FileBot
	http.HandleFunc("/filebot", requireAuth(handleFilebot))
	http.HandleFunc("/filebot/logs", requireAuth(handleFilebotLogs))
	http.HandleFunc("/api/filebot/", handleFilebotAPI)
	http.HandleFunc("/api/filebot/status", handleFilebotStatus)

	log.Printf("Dashboard démarré sur http://localhost:%s", dashboardPort)
	log.Fatal(http.ListenAndServe(":"+dashboardPort, nil))
}
