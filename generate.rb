#!/usr/bin/env ruby

require "base64"
require "cgi"
require "fileutils"
require "json"
require "net/http"
require "openssl"
require "uri"

$config = {
    :user_token => "",
    :secret_key => "",
    :data_dir => "data", # name of directory where the group data was stored
    # list of campuses to get groups for. The key is the name of the church and the value is where the groups are stored
    :campuses => { "Bellevue" => "BEL.json",
        "Sammamish" => "SAM.json",
        "Shoreline" => "SHO.json",
        "Ballard" => "BLD.json",
        "Downtown Seattle" => "DTS.json",
        "Everett" => "EVT.json",
        "U-District" => "UWD.json",
        "Rainier Valley" => "RNV.json",
        "West Seattle" => "WST.json" }
}

$output = Hash.new
unless File.directory?($config[:data_dir])
    FileUtils.mkdir_p($config[:data_dir])
end

def fetch_json(url)
    unix_time = Time.now.to_i
    http_verb = "GET"
    string_to_sign = "#{unix_time}#{http_verb}#{url}"

    unencoded_hmac = OpenSSL::HMAC.digest("sha256", $config[:secret_key], string_to_sign)
    unescaped_hmac = Base64.encode64(unencoded_hmac).chomp
    hmac_signature = CGI.escape(unescaped_hmac)

    uri = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    data = Object.new
    http.start do |http|
        request = Net::HTTP::Get.new(uri.request_uri)
        request["X-City-Sig"] = hmac_signature
        request["X-City-User-Token"] = $config[:user_token]
        request["X-City-Time"] = unix_time
        request["Accept"] = "application/vnd.thecity.admin.v1+json"
        response = http.request(request)        
        data = response.body
    end
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
            if $config[:campuses].keys.include?(campus)
                group = fetch_group(group_json)
                if !group["lat"].nil?
                    if $output[campus].nil?
                        $output[campus] = File.new("#{$config[:data_dir]}/#{$config[:campuses][campus]}", "w")
                        $output[campus].write("[")
                    else
                        $output[campus].write(",")
                    end
                    $output[campus].write(group.to_json + "\n")
                    $output[campus].flush
                else
                    puts "Skipping #{group["name"]} due to missing address"
                end
                sleep 0.5
            else
                puts "Skipping group from #{campus}"
            end
        end
    end

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
    tags = fetch_tags(id)
    address = fetch_address(id)
    day_of_week = fetch_day_of_week(tags, description)

    {
        "id" => id,
        "name" => name, 
        "church" => campus,
        "description" => description, 
        "day" => day_of_week,
        "lat" => address["lat"],
        "long" => address["long"],
        "leaders" => fetch_leaders(id),
        "tags" => tags
    }    
end

def fetch_day_of_week(tags, description)
    ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"].each do |day|
        if tags.include?(day)
            return day[0, 2]
        end
    end
    return infer_day_of_week(description)
end

def infer_day_of_week(description)
    if !description.nil?
        lower_desc = description.downcase
        if !lower_desc.match(/\bmon(day(s?))?\b/i).nil?
            return "Mo"
        elsif !lower_desc.match(/\btue(sday(s?))?\b/i).nil?
            return "Tu"
        elsif !lower_desc.match(/\bwed(nesday(s?))?\b/i).nil?
            return "We"
        elsif !lower_desc.match(/\bthur(sday(s?))?\b/i).nil?
            return "Th"
        elsif !lower_desc.match(/\bfri(day(s?))?\b/i).nil?
            return "Fr"
        elsif !lower_desc.match(/\bsatur(day(s?))?\b/i).nil?
            return "Sa"
        elsif !lower_desc.match(/\bsun(day(s?))?\b/i).nil?
            return "Su" 
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
    end

    return {
            "lat" => lat, 
            "long" => long
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

def fetch_tags(id)
    tags = Array.new
    tags_url = "https://api.onthecity.org/groups/#{id}/tags"
    tags_json = fetch_json(tags_url)["tags"]
    tags_json.each do |tag_json|
        tags << tag_json["name"]
    end

    return tags
end


fetch_groups()

manifest = File.new("#{$config[:data_dir]}/manifest.json", "w")
manifest.write("[")
$output.keys.each_with_index do |campus, index|
    if(index > 0)
        manifest.write(",")
    end
    manifest.write("\"#{$config[:campuses][campus]}\"")
    # write closing tag for all output files
    $output[campus].write("]")
end
manifest.write("]")