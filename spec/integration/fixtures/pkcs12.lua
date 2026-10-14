-- Synthetic PKCS#12 fixture shared by crypto_spec.lua and
-- activation_management_spec.lua (same convention as test_vectors.lua).
-- Generated once with OpenSSL; the encryption password is the device-key
-- password for a zero device key, base64(16 zero bytes):
-- "AAAAAAAAAAAAAAAAAAAAAA=="
-- Contains a 1024-bit RSA key + self-signed certificate. Not a real credential.
return {
    b64 = "MIIGpwIBAzCCBlUGCSqGSIb3DQEHAaCCBkYEggZCMIIGPjCCAvoGCSqGSIb3DQEH"
        .. "BqCCAuswggLnAgEAMIIC4AYJKoZIhvcNAQcBMF8GCSqGSIb3DQEFDTBSMDEGCSqG"
        .. "SIb3DQEFDDAkBBD2QrcpnDLGado6wxRZTRBJAgIIADAMBggqhkiG9w0CCQUAMB0G"
        .. "CWCGSAFlAwQBKgQQpQP0/25IWnXTMUTPVR4HPICCAnAhkiorBZui0UHnb1NWTnJ0"
        .. "wWQPnYUgqbrDLdhcnUxM8q8gqML8dxN8afAjK5lVbY1KB/rygP7rZFaZwNPkQXTK"
        .. "I9QUfwbKMBmYYZFZKB7QNncQBR+AiG7Bn/stLN1EU7ECs/iQY8JDXtw+bpuWIDfH"
        .. "7+Zco1cUKUfJi8cdYZMqwlKOmCfhbDndcPeuwDD9wlJrMer9vO3aYrodqzakThq+"
        .. "ziSjoCzokiJR/Md0DTDvosHEQhQMUOrhzCQCnH4fK5L8nD977T4HlNySlzVAV9TbF"
        .. "bkbet93hutKxVh8KoPMUKc3/wHUYV5MkL/ZGIm51lkkPGAX4ZwbugKsuKflUw5j8"
        .. "M2ZA+SI1z6DUHRBzQruj9MnW8I7iM+yPMYypAXEHKIB4YEzv3D8K7l6Abz1UOrPM"
        .. "aP94622ZG1rCelh/nqBY9Tqea0DQ0yaXLOiFELf5JY8w1ogwOxOO+DNqUxFt1ePT"
        .. "Ktn9HF4R+Eix8tRVLWQJncxLUNuPKe9ML7zX/ftgT7Zq6UUPCnyndk+98uRx0CJ5"
        .. "tDPZ9VQwotwLC+/JIGPXqHVQIsIeMfauP/0rSEZzL1wGi07VnkrxFeWSlQ8/nigG"
        .. "poWkosPc+9RtxYdE2jQXnGo2tAEl5WaC9ihhzBai7PzWuNp86eGNHYDPJjtbhwaG"
        .. "EIsHqgwCT4WviKFxwmgEK0R34Krh63Zl1JTc1EFO/o1NZWM5t1xfte8GgIuvHYfC"
        .. "CjYD+LcMjqDxh5GgwyW/UTC2RLkL2SxvZjjgvU6awl68LzhECYICQOeJBtnaa39o"
        .. "Nl+yg23DB4IBeP4ASS93gQwzt6PDcd9H3ei3AWqOSQwggM8BgkqhkiG9w0BBwGg"
        .. "ggMtBIIDKTCCAyUwggMhBgsqhkiG9w0BDAoBAqCCAukwggLlMF8GCSqGSIb3DQEF"
        .. "DTBSMDEGCSqGSIb3DQEFDDAkBBDuCqIC2HTvFp+zyXe8dbY3AgIIADAMBggqhkiG"
        .. "9w0CCQUAMB0GCWCGSAFlAwQBKgQQX6h5wh+U+Maa4s/cGhAMVQSCAoDUTGlvCccl"
        .. "vxh6Iei2v1bNV+lm0r2wYIoZPusVYy5XVp7dxycoLA7+grBEAY1UEsyNum8H8rPb"
        .. "iEUd8BH1ubpWf7H0mdGRsSMkafX0++qGuAn3iFX7KkrYJfgiP3ss7pl7S2BkPq8Z"
        .. "TzI7KUXLYNoA7flcAphRmTi7g3GZjk+JzjFjKwpSDOdvwtdTVQAWDmxyBZR5X6GX"
        .. "i9UGnI1gVEfOueXHa4+ufNd8XtZk/vYOQBP/WBPLZiBGlOD+ypUuTmZA30w8SkMM"
        .. "7OIjWttvXJ/5QmXsC2IZ471H7hIGunDuWHXKpLrRpJfOuX+NG3IJx9nW2sClIv8e"
        .. "2/8/nRhD9LFxtWERGoHcoSz9yZE7I+ndTG5t6TONUHj95lZb6F31BELh+bSWXUT9"
        .. "kRinbRTZQBaw852DQCFtNPrdCD8XxXj47AVjbnP+PMsxqH+ZSosH/DGdhjutKeos"
        .. "MsCgc0Dk3+4K8yFuggAhJzkDaqNLP5DNNwKICALg1/MdVrlwKv/odTqhLXWBTMaK"
        .. "wFGibNYz12afdUagbnRW2PgnZZ2ZEHigzO99+vRIcjqR6XzAd96JGpvHZgxh0YU6"
        .. "DuDmgqvFEybgN8k32iNfnCn4Mkd9GONW5Luxu/3qylZQr+ZZpwO10WaOG+pkXTpm"
        .. "tBzosqdQbqnD6znf+2/d6gPnkB0cqsCiWl3Xfy2aFwReS4xByCOsJQrK5XJgwf4Z"
        .. "PyOr7WJ9nuLpGCFUuL/7mj7W2yUEJb4cyJgh6F8RmH8ytpxU6hmIKU3X84DN8kW4"
        .. "uOhMaM84BJPZGW7xoQUHBgE8hNZixk9nmN/YJHAqN0RVCj4LMeuk2Ec6RXNn1WYp"
        .. "enuu0+FGs86QMSUwIwYJKoZIhvcNAQkVMRYEFF7UYerEclzDSGxj0WWwoG8mT3cM"
        .. "MEkwMTANBglghkgBZQMEAgEFAAQgeSNZrkg0rbit2CT4fvAlDB0he4YMydFcwUeD"
        .. "qz41/n4EELq0JR3dx5ouZgZMH2gVMdQCAggA",
}
