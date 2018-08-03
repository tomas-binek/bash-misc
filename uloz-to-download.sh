#!/bin/bash

## Uloz.to automated downloader
#
# This program provides automation of free download of files on uloz.to
# 
#
# Author: Tomáš Binek <tomasbinek@seznam.cz>
# Version: 1.0
#
# Design:
#
# 1. The input URL is downloaded, thus retrieving session and cookies.
#    Output file name is parsed from the HTML code.
#    Fields 'adi' and 'sign_a' are extracted from the HTML code.
# 2. An attempt, without user input, to submit captcha is done, with random input.
#    In response to this failed request, we obtain new captcha and correct values for many fields
# 3. Captcha image is displayed to the user and the user is prompted for captcha text
# 4. Captcha is submitted.
#    When failed, process is repeated from step 2.
#    With successful submit, URL of the desired file is recieved.
# 5. The file is downloaded to partial file
# 6. Downloaded file is renamed to correct name
#
# Fields of captcha-submit request:
#
# - adi            Extracted from base page
# - sign_a         Extracted from base page
# - captcha_value  User-enter captcha code
# - captcha_type   Fixed value 'xapca'
# - _do            Fixed value 'download-freeDownloadTab-freeDownloadForm-submit'
# - cid            Copied from captcha-submit response JSON, from 'new_form_values' object
# - sign           -||-
# - ts             -||-
# - _token_        -||-
# - timestamp      Copied from captcha-submit response JSON, from 'new_form_values' object where is it named xapca_(fieldname)
# - salt           -||-
# - hash           -||-


# URL-decode
# Source: https://stackoverflow.com/questions/6250698/how-to-decode-url-encoded-string-in-shell
function urldecode 
{
  echo -e "$(sed 's/+/ /g;s/%\(..\)/\\x\1/g;')"
}

# Clean up on exit
function cleanup
{
    local f
    for f in "$cookieJarFile" "$curlOutputFile" "$downloadDataFile" "$xapcaImageFile" "$headerFile"
    do
        [ -n "$f" ] && rm -f "$f"
    done
}

# General curl wrapper
# Used for debugging calls when needed
function getUrl # curlParameters...
{
    #echo "curl $@" |sed -re 's/--/\n--/g' >&2
    curl "$@"
}

# Get URL like a browser
#
# Sends User-Agent header, sends and stores cookies
# Output data is stored to $curlOutputFile unless overriden with --output option.
# On success, output data is also sent to stdout.
function getUrlLikeABrowser # url curlParameters...
{
    local url="$1"
    shift

    getUrl \
          --cookie "$cookieJarFile" \
          --cookie-jar "$cookieJarFile" \
          -H 'User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Ubuntu Chromium/67.0.3396.99 Chrome/67.0.3396.99 Safari/537.36' \
          "$@" \
          --output "$curlOutputFile" \
          "$url"

    local curlReturnCode=$?
    if [ $curlReturnCode = 0 ]
    then
        cat "$curlOutputFile"
        return 0
    else
        echo "Getting $url failed" >&2
        #cat "$curlOutputFile" >&2
        return $curlReturnCode
    fi
}

# Perfrom captcha-submitting request
# Many fields are required, refer to program description on what they are
function submitCaptcha # curlParameters...
{
    getUrlLikeABrowser "$inputUrl" \
          -H 'X-Requested-With: XMLHttpRequest' \
          -H "Referer: $inputUrl" \
          -H 'Origin: https://uloz.to' \
          -H 'Accept: application/json, text/javascript, */*; q=0.01' \
          --data "_do=download-freeDownloadTab-freeDownloadForm-submit" \
          --data "captcha_type=xapca" \
          "$@"
}

# Extract a field from JSON data
#
# @fieldSpecification is the python notation, like ['fname']
function getJsonField #fieldSpecification
{
    python -c "import sys, json; print json.load(sys.stdin)$1"
}

# Produce curl's --data argument from JSON data returned by captcha-submitting call
#
# @inputFieldName is the name of field in JSON data
# @outputFieldName is the name of --data field. If not specified, defaults to @inputFieldName
function dataFieldFromNewFormData # inputFieldName [outputFieldName]
{
    local iField="$1"
    local oField="$2"

    [ -z "$oField" ] && oField="$iField"
    echo "$oField=$(getJsonField "['new_form_values']['$iField']" < "$downloadDataFile")"
}

function xDisplayAvailable
{
    xhost &>/dev/null
}

# Prompt the user for text input
#
# Uses, in that order:
# - kdialog
# - zenity
# - command line input
function promptUser # prompt
{
	local reply

	if xDisplayAvailable && which kdialog &>/dev/null
	then
		kdialog --inputbox "$1"
	elif xDisplayAvailable && which zenity &>/dev/null
	then
		zenity --entry --text "$1"
	else
		read -p "$1" reply
		echo "$reply"
	fi
}

# Display image to user
#
# Uses, in that order
# - feh
# - img2txt (libcaca command to display image as text)
#
# If none of the above methods is available, prints the image URL with a message.
function displayImage # imageFile imageUrl
{
    if xDisplayAvailable && which feh &>/dev/null
    then
        feh "$1" &
        imageViewerPid=$!
    elif which img2txt &>/dev/null
    then
        img2txt --format utf8 --width $(tput cols) --height $(tput lines) "$1"
    else
        echo "There's no way to display captcha image to you now. Install 'feh' and connect X display, or install 'img2txt' (part of caca-utils)." >&2
        echo "Image is located at $2, or in $1" >&2
    fi
}

# Notify the user and exit program
#
# The message is displayed in X window, if that is available.
# It is printed to terminal always.
function _exit # exitCode [message]
{
    local userMessage=
    
    if [ $1 = 0 ]
    then
        userMessage="Successfully downloaded $completeOutputFile from $inputUrl"
    else
        userMessage="Failed to download $inputUrl. Exiting with $1, saying: $2"
    fi
    
    if xDisplayAvailable
    then
        xmessage "$userMessage"
    fi
    
    echo "$userMessage" >&2
    exit $1
}




# Input parameters
inputUrl="$1"
[ -n "$inputUrl" ] \
|| { _exit 1 "Input url is missing"; }


# Preparation
trap cleanup EXIT
cookieJarFile="$(mktemp)"
curlOutputFile="$(mktemp)"
headerFile="$(mktemp)"
downloadDataFile="$(mktemp)"
xapcaImageFile="$(mktemp)"
xapcaImageUrl=
xapcaText=
imageViewerPid=
data_adi=
data_sign_a=
fileUrl=
temporaryOutputFile=
completeOutputFile=

echo "Downloading $inputUrl" >&2

# Download input URL
getUrlLikeABrowser "$inputUrl" --silent >/dev/null \
|| { _exit 2 "Failed getting $inputUrl"; }

# Extract output file name
completeOutputFile=$(sed -nre 's|<meta itemprop="name" content="([^"]+)">.*|\1|p' < "$curlOutputFile")
if [ -z "$completeOutputFile" ]
then
    completeOutputFile="File from $(tr '/' '_' <<< "$inputUrl").data"
    echo "Failed to extract file name from page." >&2
    echo "File will be named '$completeOutputFile'" >&2
fi

# Construct temporary output file name
temporaryOutputFile="$completeOutputFile.part"

# Extract fields 'adi', 'sign_a'
data_adi="$(sed -re 's/>/>\n/g' <"$curlOutputFile" |sed -nre 's/<input type="hidden" name="adi" id="[^"]+" value="([^"]+)">/\1/p')"
data_sign_a="$(sed -re 's/>/>\n/g' <"$curlOutputFile" |sed -nre 's/<input type="hidden" name="sign_a" id="[^"]+" value="([^"]+)">/\1/p')"
[ -z "$data_adi" -o -z "$data_sign_a" ] && { _exit 2 "Failed to extract fields from page"; }

# Submit captcha and download
while true
do
    # Get correct values by failing the first captcha
    submitCaptcha --silent --data "captcha_value=$RANDOM" >"$downloadDataFile" \
    || { _exit 2 "Failed to get form data"; }

    # Download xapca image
    xapcaImageUrl="https:$(getJsonField "['new_captcha_data']['image']" <"$downloadDataFile")"
    getUrlLikeABrowser "$xapcaImageUrl" --silent >"$xapcaImageFile" \
    || { _exit 2 "Failed to get captcha image from $xapcaImageUrl"; }

    # Get captcha text from user
    displayImage "$xapcaImageFile" "$xapcaImageUrl"
    xapcaText="$(promptUser 'Captcha:')"
    [ "$imageViewerPid" ] && kill $imageViewerPid

    # Get file url
    submitCaptcha --silent \
        --data "captcha_value=$xapcaText" \
        --data "freeDownload=" \
        --data "adi=$data_adi" \
        --data "sign_a=$data_sign_a" \
        $(for fieldName in cid sign ts _token_; do echo "--data $(dataFieldFromNewFormData "$fieldName")"; done) \
        $(for fieldName in timestamp salt hash; do echo "--data $(dataFieldFromNewFormData "xapca_$fieldName" "$fieldName")"; done) \
        >/dev/null \
    || { _exit 2 "Failed when submitting captcha"; }

    # Check response
    if egrep -q '^\{"status":"error"' < "$curlOutputFile"
    then
        echo "Captcha submission failed: $(getJsonField "['errors']" < "$curlOutputFile")" >&2
        echo "Try again" >&2
        continue
    fi

    # Extract download url
    fileUrl="$(getJsonField "['url']" < "$curlOutputFile")"
    [ -z "$fileUrl" ] && { cat "$curlOutputFile" >&2; _exit 3 "Failed to extract file url"; }
    
    # Download the file
    getUrl -L --retry 10 --dump-header "$headerFile" "$fileUrl" >"$temporaryOutputFile" \
    || { echo "Failed to download the file" >&2; continue; }

    # Rename file
    mv "$temporaryOutputFile" "$completeOutputFile"    
    
    # Done
    _exit 0
done
