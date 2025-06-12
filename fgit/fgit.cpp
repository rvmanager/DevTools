#include <iostream>
#include <string>
#include <fstream>
#include <filesystem>
#include <cstdlib>
#include <memory>
#include <stdexcept>
#include <sstream>
#include <curl/curl.h>
#include <nlohmann/json.hpp>

using json = nlohmann::json;
namespace fs = std::filesystem;

class FGit {
private:
    std::string gemini_api_key;
    std::string git_remote = "origin";
    std::string git_branch = "main";
    std::string base_prompt = "Create a concise git commit message based on the following git diff. "
                             "The message should follow standard conventions (e.g., imperative mood, short subject line, optional body). "
                             "In the body, use a bulleted list (dashes). Do not include the diff itself in the message, only the generated commit message text.";
    
    static size_t WriteCallback(void* contents, size_t size, size_t nmemb, std::string* userp) {
        userp->append((char*)contents, size * nmemb);
        return size * nmemb;
    }
    
    std::string execute_command(const std::string& command) {
        std::array<char, 128> buffer;
        std::string result;
        std::unique_ptr<FILE, decltype(&pclose)> pipe(popen(command.c_str(), "r"), pclose);
        
        if (!pipe) {
            throw std::runtime_error("popen() failed!");
        }
        
        while (fgets(buffer.data(), buffer.size(), pipe.get()) != nullptr) {
            result += buffer.data();
        }
        
        return result;
    }
    
    int execute_command_with_status(const std::string& command) {
        return system(command.c_str());
    }
    
    void load_config() {
        std::string home_dir = std::getenv("HOME");
        fs::path config_path = fs::path(home_dir) / ".fgit.conf";
        
        if (!fs::exists(config_path)) {
            throw std::runtime_error("Config file ~/.fgit.conf not found. Please create it with your Gemini API key.");
        }
        
        std::ifstream config_file(config_path);
        if (!config_file.is_open()) {
            throw std::runtime_error("Could not open config file ~/.fgit.conf");
        }
        
        std::string line;
        while (std::getline(config_file, line)) {
            // Skip empty lines and comments
            if (line.empty() || line[0] == '#') continue;
            
            // Look for GEMINI_API_KEY=value
            size_t pos = line.find("GEMINI_API_KEY=");
            if (pos != std::string::npos) {
                gemini_api_key = line.substr(pos + 15);
                // Remove quotes if present
                if (gemini_api_key.front() == '"' && gemini_api_key.back() == '"') {
                    gemini_api_key = gemini_api_key.substr(1, gemini_api_key.length() - 2);
                }
                break;
            }
        }
        
        if (gemini_api_key.empty()) {
            throw std::runtime_error("GEMINI_API_KEY not found in ~/.fgit.conf");
        }
    }
    
    void check_dependencies() {
        // Check for git
        if (system("which git > /dev/null 2>&1") != 0) {
            throw std::runtime_error("git is not installed or not in PATH");
        }
        
        // Check for curl (though we're using libcurl)
        if (system("which curl > /dev/null 2>&1") != 0) {
            throw std::runtime_error("curl is not installed or not in PATH");
        }
    }
    
    std::string get_git_diff() {
        std::cout << "Fetching git diff (staged files)..." << std::endl;
        
        try {
            std::string diff_output = execute_command("git diff --staged --unified=8 --function-context --no-color --stat");
            
            if (diff_output.empty()) {
                std::cout << "No staged changes detected. Nothing to commit." << std::endl;
                exit(0);
            }
            
            return diff_output;
        } catch (const std::exception& e) {
            throw std::runtime_error("Failed to get git diff: " + std::string(e.what()));
        }
    }
    
    std::string call_gemini(const std::string& diff_content) {
        CURL* curl;
        CURLcode res;
        std::string response_data;
        
        curl = curl_easy_init();
        if (!curl) {
            throw std::runtime_error("Failed to initialize curl");
        }
        
        // Prepare the prompt
        std::string prompt_text = base_prompt + "\n\n```diff\n" + diff_content + "\n```";
        
        // Create JSON payload
        json payload = {
            {"contents", {{
                {"parts", {{
                    {"text", prompt_text}
                }}}
            }}}
        };
        
        std::string json_string = payload.dump();
        std::string url = "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash-latest:generateContent?key=" + gemini_api_key;
        
        // Set curl options
        curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
        curl_easy_setopt(curl, CURLOPT_POSTFIELDS, json_string.c_str());
        curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, WriteCallback);
        curl_easy_setopt(curl, CURLOPT_WRITEDATA, &response_data);
        
        // Set headers
        struct curl_slist* headers = nullptr;
        headers = curl_slist_append(headers, "Content-Type: application/json");
        curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
        
        std::cout << "Calling Gemini API..." << std::endl;
        
        // Perform the request
        res = curl_easy_perform(curl);
        
        // Clean up
        curl_slist_free_all(headers);
        curl_easy_cleanup(curl);
        
        if (res != CURLE_OK) {
            throw std::runtime_error("curl_easy_perform() failed: " + std::string(curl_easy_strerror(res)));
        }
        
        // Parse JSON response
        try {
            json response = json::parse(response_data);
            
            // Check for API errors
            if (response.contains("error")) {
                std::stringstream error_msg;
                error_msg << "Gemini API returned an error: " << response["error"];
                throw std::runtime_error(error_msg.str());
            }
            
            // Extract the generated text
            if (response.contains("candidates") && 
                !response["candidates"].empty() &&
                response["candidates"][0].contains("content") &&
                response["candidates"][0]["content"].contains("parts") &&
                !response["candidates"][0]["content"]["parts"].empty() &&
                response["candidates"][0]["content"]["parts"][0].contains("text")) {
                
                return response["candidates"][0]["content"]["parts"][0]["text"];
            } else {
                throw std::runtime_error("Could not extract commit message from Gemini response");
            }
            
        } catch (const json::parse_error& e) {
            throw std::runtime_error("Failed to parse JSON response: " + std::string(e.what()));
        }
    }
    
    char get_user_choice() {
        std::cout << "Apply this commit message? (y/n/redo) ";
        std::cout.flush();
        
        // Set terminal to raw mode to read single character
        system("stty raw -echo");
        char choice = std::getchar();
        system("stty cooked echo");
        
        // Print the character and move to new line
        std::cout << choice << std::endl;
        
        return std::tolower(choice);
    }
    
    void perform_git_operations(const std::string& commit_message) {
        std::cout << "Proceeding with commit..." << std::endl;
        
        // Git commit (staged files are already staged)
        std::cout << "Running: git commit -m \"<message>\"" << std::endl;
        
        // Create a temporary file for the commit message to avoid shell escaping issues
        std::string temp_file = "/tmp/fgit_commit_msg.txt";
        std::ofstream msg_file(temp_file);
        msg_file << commit_message;
        msg_file.close();
        
        std::string commit_cmd = "git commit -F " + temp_file;
        if (execute_command_with_status(commit_cmd) != 0) {
            fs::remove(temp_file);
            throw std::runtime_error("git commit failed");
        }
        
        fs::remove(temp_file);
        
        // Git push
        std::cout << "Running: git push " << git_remote << " " << git_branch << std::endl;
        std::string push_cmd = "git push " + git_remote + " " + git_branch;
        if (execute_command_with_status(push_cmd) != 0) {
            std::cerr << "Error: git push failed. Your commit was created locally, but not pushed." << std::endl;
            exit(1);
        }
        
        std::cout << "Commit created and pushed successfully!" << std::endl;
    }
    
public:
    void run() {
        try {
            // Initialize
            load_config();
            check_dependencies();
            
            // Get git diff
            std::string diff_output = get_git_diff();
            
            // Main interaction loop
            while (true) {
                try {
                    std::string suggested_message = call_gemini(diff_output);
                    
                    std::cout << "--------------------------------------------------" << std::endl;
                    std::cout << "Suggested commit message:" << std::endl;
                    std::cout << std::endl;
                    std::cout << suggested_message << std::endl;
                    std::cout << std::endl;
                    std::cout << "--------------------------------------------------" << std::endl;
                    
                    char choice = get_user_choice();
                    
                    switch (choice) {
                        case 'y':
                            perform_git_operations(suggested_message);
                            return; // Exit successfully
                            
                        case 'n':
                            std::cout << "Aborting." << std::endl;
                            return;
                            
                        case 'r':
                            std::cout << "Requesting a new suggestion..." << std::endl;
                            break; // Continue loop
                            
                        default:
                            std::cout << "Invalid choice. Please enter y, n, or r." << std::endl;
                            break; // Continue loop with same message
                    }
                    
                } catch (const std::exception& e) {
                    std::cerr << "Failed to get suggestion from Gemini: " << e.what() << std::endl;
                    std::cerr << "Aborting." << std::endl;
                    exit(1);
                }
            }
            
        } catch (const std::exception& e) {
            std::cerr << "Error: " << e.what() << std::endl;
            exit(1);
        }
    }
};

int main() {
    // Initialize curl globally
    curl_global_init(CURL_GLOBAL_DEFAULT);
    
    FGit fgit;
    fgit.run();
    
    // Clean up curl
    curl_global_cleanup();
    
    return 0;
}
