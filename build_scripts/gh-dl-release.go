package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io/ioutil"
	"log"
	"net/http"
	"os"
)

var (
	tokenPtr   = flag.String("token", "", "Github Token.")
	repoPtr    = flag.String("repo", "", "Repo to fetch release from.")
	versionPtr = flag.String("version", "latest", "Version of release to fetch.")
	filePtr    = flag.String("file", "", "The file you want to download from release.")
)

type Releases []struct {
	ID      int    `json:"id"`
	TagName string `json:"tag_name"`
	Name    string `json:"name"`
	Assets  []struct {
		URL   string `json:"url"`
		ID    int    `json:"id"`
		Name  string `json:"name"`
		State string `json:"state"`
	} `json:"assets"`
}

func init() {
	flag.Parse()
	flag.VisitAll(func(f *flag.Flag) {
		if f.Value.String() == "" {
			log.Fatalf("missing required %s flag", f.Name)
			os.Exit(2)
		}
	})
}

func fetchReleases() (string, error) {
	req, err := http.NewRequest("GET", fmt.Sprintf("https://api.github.com/repos/%s/releases", *repoPtr), nil)
	if err != nil {
		return "", err
	}

	req.Header.Set("Authorization", fmt.Sprintf("token %s", *tokenPtr))
	req.Header.Set("Accept", "application/json")

	client := &http.Client{}
	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	if resp.StatusCode != 200 {
		body, _ := ioutil.ReadAll(resp.Body)
		return "", fmt.Errorf("Received %v Status Code: %v.", resp.StatusCode, body)
	}

	body, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return "", err
	}

	var releases Releases
	err = json.Unmarshal(body, &releases)
	if err != nil {
		return "", err
	}

	if *versionPtr == "latest" {
		return releases[0].Assets[0].URL, nil
	}

	for _, release := range releases {
		if release.TagName == *versionPtr {
			for _, asset := range release.Assets {
				if *filePtr == asset.Name {
					return fmt.Sprintf("https://api.github.com/repos/%v/releases/assets/%v", *repoPtr, asset.ID), nil
				}
			}
		}
	}

	return "", fmt.Errorf("Could not find file %s to download.", *filePtr)
}

func downloadRelease(url string) error {
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return err
	}

	req.Header.Set("Authorization", fmt.Sprintf("token %s", *tokenPtr))
	req.Header.Set("Accept", "application/octet-stream")

	client := &http.Client{}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	if resp.StatusCode != 200 {
		body, _ := ioutil.ReadAll(resp.Body)
		return fmt.Errorf("Received %v Status Code: %v.", resp.StatusCode, body)
	}

	body, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return err
	}

	err = ioutil.WriteFile(*filePtr, body, 0755)
	if err != nil {
		return err
	}

	return nil
}

func main() {
	releaseURL, err := fetchReleases()
	if err != nil {
		log.Fatalln(err)
		os.Exit(1)
	}
	err = downloadRelease(releaseURL)
	if err != nil {
		log.Fatalln(err)
		os.Exit(1)
	}
}