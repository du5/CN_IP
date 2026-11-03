package main

import (
	"bytes"
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
	// 该仓库用 Git LFS 存储，raw.githubusercontent.com 只会返回 LFS 指针，
	// 必须走 github.com 的 raw 重定向到 media.githubusercontent.com。
	geoIPURL  = "https://github.com/du5/geoip/raw/main/GeoLite2-Country.mmdb"
	outFile   = "CN.txt"
	targetISO = "CN"
)

var allIPv4 = netip.MustParsePrefix("0.0.0.0/0")

func main() {
	if err := run(); err != nil {
		log.Fatal(err)
	}
}

func run() error {
	data, err := downloadGeoLite2Country()
	if err != nil {
		return err
	}

	db, err := maxminddb.OpenBytes(data)
	if err != nil {
		return fmt.Errorf("open GeoLite2 database: %w", err)
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

// downloadGeoLite2Country 每次运行都把最新的数据库下载到内存，不在本地缓存。
// 定时任务跑在全新的 runner 上，本地缓存和时效判断没有意义。
func downloadGeoLite2Country() ([]byte, error) {
	log.Printf("Downloading %s ...", geoIPURL)
	client := &http.Client{Timeout: 2 * time.Minute}
	resp, err := client.Get(geoIPURL)
	if err != nil {
		return nil, fmt.Errorf("download GeoLite2 database: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("download GeoLite2 database: HTTP %d", resp.StatusCode)
	}
	data, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("download GeoLite2 database: %w", err)
	}
	if bytes.HasPrefix(data, []byte("version https://git-lfs.github.com/")) {
		return nil, fmt.Errorf("download GeoLite2 database: got a Git LFS pointer instead of the file, check %s", geoIPURL)
	}
	return data, nil
}
