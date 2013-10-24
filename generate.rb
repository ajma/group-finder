#!/usr/bin/env ruby

require "openssl"
require "cgi"
require "base64"
require "net/http"
require "uri"
require "json"

$secret_key = ""
$user_token = ""

$campus_names = ["Bellevue", "Sammamish", "Shoreline", "Ballard", "Downtown Seattle", "Everett", "U-District", "West Seattle"]

$file = File.open('groups.json', 'w')
$first = true

def fetch_json(url)
    unix_time = Time.now.to_i
    http_verb = "GET"
    string_to_sign = "#{unix_time}#{http_verb}#{url}"

    unencoded_hmac = OpenSSL::HMAC.digest("sha256", $secret_key, string_to_sign)
    unescaped_hmac = Base64.encode64(unencoded_hmac).chomp
    hmac_signature = CGI.escape(unescaped_hmac)

    uri = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    request = Net::HTTP::Get.new(uri.request_uri)
    request["X-City-Sig"] = hmac_signature
    request["X-City-User-Token"] = $user_token
    request["X-City-Time"] = unix_time
    request["Accept"] = "application/vnd.thecity.admin.v1+json"
    response = http.request(request)
    
    data = response.body
    return JSON.parse(data)
end

def fetch_groups(page = 1)
    groups_url = "https://api.onthecity.org/groups?group_types=CG&page=#{page}"
    # puts groups_url
    json = fetch_json(groups_url)
    groups_json = json["groups"]
    total_pages = json["total_pages"]    
    puts "Fetching groups page #{page} of #{total_pages}"

    groups_json.each do |group_json|
        campus = group_json["campus_name"]
        if !campus.nil?
            campus = campus.strip
            if $campus_names.include?(campus)
                group = fetch_group(group_json)
                if !group["address"]["lat"].nil?
                    if $first
                        $first = false
                    else
                        $file.write(",")
                    end
                    $file.write(group.to_json + "\n")
                else
                    puts "Skipping #{group["name"]} due to missing address"
                end
                sleep 0.5
            else
                puts "Skipping group from #{campus}"
            end
        end
    end
    $file.flush

    if page < total_pages
        fetch_groups(page + 1)
    end
end

def fetch_group(group_json)
    id = group_json["id"]
    name = group_json["name"]
    puts "  Processing group #{id}: #{name}"
    url = group_json["internal_url"]
    campus = group_json["campus_name"]
    description = group_json["external_description"]
    day_of_week = infer_day_of_week(description)

    {
        "id" => id,
        "name" => name, 
        "church" => campus,
        "description" => description, 
        "day_of_week" => day_of_week,
        "address" => fetch_address(id),
        "leaders" => fetch_leaders(id)
    }    
end

def infer_day_of_week(description)
    if !description.nil?
        lower_desc = description.downcase
        if !lower_desc.match(/\bmon(day(s?))?\b/i).nil?
            return "Monday"
        elsif !lower_desc.match(/\btue(sday(s?))?\b/i).nil?
            return "Tuesday"
        elsif !lower_desc.match(/\bwed(nesday(s?))?\b/i).nil?
            return "Wednesday"
        elsif !lower_desc.match(/\bthur(sday(s?))?\b/i).nil?
            return "Thursday"
        elsif !lower_desc.match(/\bfri(day(s?))?\b/i).nil?
            return "Friday"
        elsif !lower_desc.match(/\bsatur(day(s?))?\b/i).nil?
            return "Saturday"
        elsif !lower_desc.match(/\bsun(day(s?))?\b/i).nil?
            return "Sunday" 
        end
    end 
    return "Not Listed" 
end

def fetch_address(id)
    address_url = "https://api.onthecity.org/groups/#{id}/addresses"
    json = fetch_json(address_url)
    address = json["addresses"][0]

    if address
        lat = address["latitude"]
        long = address["longitude"]
        street = address["street"]
        street2 = address["street2"]
        city = address["city"]
        state = address["state"]
        zipcode = address["zipcode"]
    end

    return {
            "lat" => lat, 
            "long" => long, 
            "street" => street, 
            "street2" => street2, 
            "city" => city, 
            "state" => state, 
            "zipcode" => zipcode
        }
end

def fetch_leaders(id)
    leaders = Array.new
    leaders_url = "https://api.onthecity.org/groups/#{id}/roles?title=Leaders"
    leaders_json = fetch_json(leaders_url)["roles"]
    leaders_json.each do |leader_json|
        user_id = leader_json["user_id"]
        user_url = "https://api.onthecity.org/users/#{user_id}"
        user_json = fetch_json(user_url)
        leaders << { "name" => leader_json["user_name"],
            "email" => user_json["email"] }
    end

    return leaders
end

$file.write("[\n")
fetch_groups()
$file.write("]")
