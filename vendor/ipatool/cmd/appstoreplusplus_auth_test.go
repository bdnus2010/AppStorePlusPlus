package cmd

import (
    "context"
    "os"
    "path/filepath"

    "github.com/majd/ipatool/v2/pkg/appstore"
    "github.com/majd/ipatool/v2/pkg/log"
    . "github.com/onsi/ginkgo/v2"
    . "github.com/onsi/gomega"
)

var _ = Describe("AppStore++ private credential pipe", func() {
    DescribeTable("reads credentials without command-line secrets", func(payload, expectedError string, expected appstore.LoginInput) {
        previous := dependencies
        DeferCleanup(func() { dependencies = previous })
        store := &fakeLoginAppStore{}
        dependencies.AppStore = store
        dependencies.Logger = log.NewLogger(log.Args{})
        path := filepath.Join(GinkgoT().TempDir(), "stdin")
        Expect(os.WriteFile(path, []byte(payload), 0600)).To(Succeed())
        input, err := os.Open(path)
        Expect(err).NotTo(HaveOccurred())
        DeferCleanup(input.Close)
        previousInput := os.Stdin
        os.Stdin = input
        DeferCleanup(func() { os.Stdin = previousInput })
        command := loginCmd()
        command.SilenceErrors, command.SilenceUsage = true, true
        command.SetContext(context.WithValue(context.Background(), interactiveKey, false))
        command.SetArgs([]string{"--credentials-stdin"})
        err = command.Execute()
        if expectedError != "" {
            Expect(err).To(MatchError(expectedError))
            Expect(store.loginCalls).To(BeZero())
        } else {
            Expect(err).NotTo(HaveOccurred())
            Expect(store.input).To(Equal(expected))
            Expect(store.loginCalls).To(Equal(1))
        }
    },
        Entry("password and account", `{"Email":"person@example.test","Password":"a'$(not-a-command)"}`, "", appstore.LoginInput{Email:"person@example.test", Password:"a'$(not-a-command)"}),
        Entry("verification code", `{"Email":"person@example.test","Password":"secret","AuthCode":"123456"}`, "", appstore.LoginInput{Email:"person@example.test", Password:"secret", AuthCode:"123456"}),
        Entry("malformed input", `{`, "could not read sign-in credentials", appstore.LoginInput{}),
        Entry("empty input", ``, "could not read sign-in credentials", appstore.LoginInput{}),
    )
})
