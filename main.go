package main

import (
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/netip"
	"os"
	"strings"
	"time"

	maxminddb "github.com/oschwald/maxminddb-golang/v2"
	"go4.org/netipx"
)

const (
	geoIPDB = "GeoLite2-Country.mmdb"
	// 该仓库用 Git LFS 存储，raw.githubusercontent.com 只会返回 LFS 指针，
	// 必须走 github.com 的 raw 重定向到 media.githubusercontent.com。
	geoIPURL  = "https://github.com/du5/geoip/raw/main/GeoLite2-Country.mmdb"
	outFile   = "CN.txt"
	targetISO = "CN"

	// 本地数据库超过这个时长未更新就重新下载
	geoIPMaxAge = 6 * time.Hour
)

var allIPv4 = netip.MustParsePrefix("0.0.0.0/0")

func main() {
	if err := run(); err != nil {
		log.Fatal(err)
	}
}

func run() error {
	if err := ensureGeoLite2Country(); err != nil {
		return err
	}

	db, err := maxminddb.Open(geoIPDB)
	if err != nil {
		return err
	}
	defer db.Close()

	// 直接遍历数据库中的网段，而不是逐个查询 2^32 个地址。
	// 数据库本身就是前缀树，每个网段只需解码一次。
	var (
		builder netipx.IPSetBuilder
		scanned int
	)
	for res := range db.NetworksWithin(allIPv4) {
		if err := res.Err(); err != nil {
			return err
		}
		scanned++
		code, err := countryCode(res)
		if err != nil {
			return fmt.Errorf("decode %s: %w", res.Prefix(), err)
		}
		if code == targetISO {
			builder.AddPrefix(res.Prefix())
		}
	}

	ipSet, err := builder.IPSet()
	if err != nil {
		return err
	}
	prefixes := ipSet.Prefixes()

	var sb strings.Builder
	for _, p := range prefixes {
		sb.WriteString(p.String())
		sb.WriteByte('\n')
	}
	if err := os.WriteFile(outFile, []byte(sb.String()), 0o644); err != nil {
		return err
	}

	log.Printf("Scanned %d networks, wrote %d CIDR blocks to %s", scanned, len(prefixes), outFile)
	return nil
}

// countryCode 优先取 country.iso_code，为空时回退到 registered_country.iso_code。
func countryCode(res maxminddb.Result) (string, error) {
	var code string
	if err := res.DecodePath(&code, "country", "iso_code"); err != nil {
		return "", err
	}
	if code != "" {
		return code, nil
	}
	if err := res.DecodePath(&code, "registered_country", "iso_code"); err != nil {
		return "", err
	}
	return code, nil
}

// ensureGeoLite2Country 在本地没有数据库文件，或文件修改时间超过 geoIPMaxAge 时下载一份。
// 删除本地的 GeoLite2-Country.mmdb 即可强制重新下载。
func ensureGeoLite2Country() error {
	info, err := os.Stat(geoIPDB)
	switch {
	case err == nil:
		age := time.Since(info.ModTime())
		if age < geoIPMaxAge {
			log.Printf("Using existing %s (updated %s ago)", geoIPDB, age.Round(time.Minute))
			return nil
		}
		log.Printf("%s is %s old, exceeds %s", geoIPDB, age.Round(time.Minute), geoIPMaxAge)
	case errors.Is(err, os.ErrNotExist):
	default:
		return err
	}

	log.Printf("Downloading %s ...", geoIPDB)
	client := &http.Client{Timeout: 2 * time.Minute}
	resp, err := client.Get(geoIPURL)
	if err != nil {
		return fmt.Errorf("download %s: %w", geoIPDB, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("download %s: HTTP %d", geoIPDB, resp.StatusCode)
	}

	// 先写到临时文件，成功后再改名，避免留下半截文件。
	tmp := geoIPDB + ".tmp"
	f, err := os.Create(tmp)
	if err != nil {
		return err
	}
	if _, err := io.Copy(f, resp.Body); err != nil {
		f.Close()
		os.Remove(tmp)
		return fmt.Errorf("download %s: %w", geoIPDB, err)
	}
	if err := f.Close(); err != nil {
		os.Remove(tmp)
		return err
	}

	// 校验下载内容确实是 MaxMind DB，避免把错误文件留在本地导致下次跳过下载。
	db, err := maxminddb.Open(tmp)
	if err != nil {
		os.Remove(tmp)
		return fmt.Errorf("downloaded %s is not a valid MaxMind DB: %w", geoIPDB, err)
	}
	db.Close()
	return os.Rename(tmp, geoIPDB)
}
