//  File: pptt/pptt.cpp
#include <iostream>
#include <string>
#include <vector>
#include <filesystem>
#include <fstream>
#include <algorithm>
#include <set>
#include <map>
#include <sstream>
#include <cctype>
#include <regex>
#include <unistd.h> // for getopt
#include <iomanip>

namespace fs = std::filesystem;

struct PatternFilter {
    std::string pattern;
    bool is_include; // true for -e, false for -v
};

struct CommentStyle {
    std::string single_line;
    std::string multi_start;
    std::string multi_end;
    bool has_comments;
};

class TreePrinter {
private:
    std::vector<PatternFilter> pattern_filters;
    bool show_dir_only = false;
    bool show_line_numbers = false;
    mutable std::set<std::string> unknown_extensions; // Track unknown extensions
    fs::path base_directory; // Store base directory for relative path calculations
    
    // Comment styles lookup table
    std::map<std::string, CommentStyle> comment_styles = {
        {".cpp", {"//", "/*", "*/", true}},
        {".c", {"//", "/*", "*/", true}},
        {".h", {"//", "/*", "*/", true}},
        {".hpp", {"//", "/*", "*/", true}},
        {".swift", {"//", "/*", "*/", true}},
        {".sh", {"#", "", "", true}},
        {".bash", {"#", "", "", true}},
        {".py", {"#", "'''", "'''", true}},
        {".js", {"//", "/*", "*/", true}},
        {".ts", {"//", "/*", "*/", true}},
        {".java", {"//", "/*", "*/", true}},
        {".cs", {"//", "/*", "*/", true}},
        {".go", {"//", "/*", "*/", true}},
        {".php", {"//", "/*", "*/", true}},
        {".rb", {"#", "=begin", "=end", true}},
        {".rs", {"//", "/*", "*/", true}},
        {".lua", {"--", "--[[", "]]", true}},
        {".html", {"", "<!--", "-->", true}},
        {".xml", {"", "<!--", "-->", true}},
        {".yaml", {"#", "", "", true}},
        {".yml", {"#", "", "", true}},
        {".json", {"", "", "", false}},
        {".ini", {"#", "", "", true}},
        {".sql", {"--", "/*", "*/", true}},
        {".tex", {"%", "", "", true}},
        {".md", {"", "", "", false}},
        {".cmake", {"#", "", "", true}},
        {".txt", {"", "", "", false}},
        {".proto", {"//", "/*", "*/", true}},
        {".ex", {"#", "", "", true}},
        {".exs", {"#", "", "", true}},
        {".pl", {"#", "", "", true}}
    };
    
    bool matches_patterns(const fs::path& full_path) const {
        if (pattern_filters.empty()) {
            return true; // No filters means include everything
        }
    
        // Get relative path from base directory
        fs::path relative_path;
        try {
            relative_path = fs::relative(full_path, base_directory);
        } catch (const fs::filesystem_error&) {
            // If we can't get relative path, use the full path
            relative_path = full_path;
        }
        
        // Convert to string with forward slashes (consistent across platforms)
        std::string path_str = relative_path.string();
        std::replace(path_str.begin(), path_str.end(), '\\', '/');
        
        bool has_include_filters = false;
        bool has_exclude_filters = false;
        bool matches_include = false;
        bool matches_exclude = false;
        
        // First, determine what types of filters we have and check matches
        for (const auto& filter : pattern_filters) {
            try {
                std::regex pattern_regex(filter.pattern);
                bool matches = std::regex_search(path_str, pattern_regex);
                
                if (filter.is_include) {
                    has_include_filters = true;
                    if (matches) {
                        matches_include = true;
                    }
                } else {
                    has_exclude_filters = true;
                    if (matches) {
                        matches_exclude = true;
                    }
                }
            } catch (const std::regex_error& e) {
                std::cerr << "Invalid regex pattern '" << filter.pattern << "': " << e.what() << std::endl;
                return false;
            }
        }
        
        // Apply the logic:
        // 1. If there are exclude filters and item matches any, exclude it
        if (has_exclude_filters && matches_exclude) {
            return false;
        }
        
        // 2. If there are include filters, item must match at least one
        if (has_include_filters) {
            return matches_include;
        }
        
        // 3. If only exclude filters (and we got here), include it
        return true;
    } 

    CommentStyle get_comment_style(const fs::path& file_path) const {
        std::string extension = file_path.extension().string();
        std::transform(extension.begin(), extension.end(), extension.begin(), ::tolower);
        
        auto it = comment_styles.find(extension);
        if (it != comment_styles.end()) {
            return it->second;
        }
        
        // Track unknown extensions (only if they have an extension)
        if (!extension.empty() && extension != ".") {
            unknown_extensions.insert(extension);
        }
        
        // Default: no comments
        return {"", "", "", false};
    }
    
    bool is_binary(const fs::path& file_path) const {
        std::ifstream file(file_path, std::ios::binary);
        if (!file.is_open()) {
            return true; // Assume binary if can't open
        }
        
        // Read first 512 bytes to check for binary content
        char buffer[512];
        file.read(buffer, sizeof(buffer));
        std::streamsize bytes_read = file.gcount();
        
        if (bytes_read == 0) {
            return false; // Empty file is considered text
        }
        
        // Check for null bytes (definitive indicator of binary files)
        for (std::streamsize i = 0; i < bytes_read; ++i) {
            if (buffer[i] == '\0') {
                return true;
            }
        }
        
        // Check for high ratio of non-printable characters
        int non_printable = 0;
        for (std::streamsize i = 0; i < bytes_read; ++i) {
            unsigned char c = static_cast<unsigned char>(buffer[i]);
            // Allow common whitespace characters
            if (c < 32 && c != '\t' && c != '\n' && c != '\r') {
                non_printable++;
            }
            // Check for extended ASCII that might indicate binary
            if (c > 126) {
                non_printable++;
            }
        }
        
        // If more than 30% non-printable, consider it binary
        return (non_printable * 100 / bytes_read > 30);
    }
    
    void print_tree(const fs::path& dir, const std::string& prefix, std::vector<fs::path>& visible_files) const {
        if (!fs::exists(dir) || !fs::is_directory(dir)) {
            return;
        }
        
        std::vector<fs::directory_entry> entries;
        
        // Collect all entries
        try {
            for (const auto& entry : fs::directory_iterator(dir)) {
                // Skip hidden files (starting with .)
                std::string filename = entry.path().filename().string();
                if (filename[0] != '.') {
                    entries.push_back(entry);
                }
            }
        } catch (const fs::filesystem_error& e) {
            std::cerr << "Error reading directory " << dir << ": " << e.what() << std::endl;
            return;
        }
        
        // Sort entries
        std::sort(entries.begin(), entries.end(), 
                [](const fs::directory_entry& a, const fs::directory_entry& b) {
                    return a.path().filename() < b.path().filename();
                });
        
        // Print entries and collect visible files
        for (const auto& entry : entries) {
            std::string filename = entry.path().filename().string();
            
            if (entry.is_directory()) {
                // Check if directory matches patterns
                if (matches_patterns(entry.path())) {
                    std::cout << prefix << "|_ " << filename << std::endl;
                    print_tree(entry.path(), prefix + "|     ", visible_files);
                } else {
                    // Directory doesn't match patterns, but explore if it might contain matching items
                    if (directory_contains_matches(entry.path())) {
                        print_tree(entry.path(), prefix, visible_files);
                    }
                }
            } else if (entry.is_regular_file()) {
                // Check if file matches patterns
                if (matches_patterns(entry.path())) {
                    std::cout << prefix << "|_ " << filename << std::endl;
                    visible_files.push_back(entry.path());
                }
            }
        }
    }
    
    int count_digits(int number) const {
        if (number == 0) return 1;
        int digits = 0;
        while (number > 0) {
            number /= 10;
            digits++;
        }
        return digits;
    }
    
    void print_file_content_with_lines(const fs::path& file_path) const {
        std::ifstream file(file_path);
        if (!file.is_open()) {
            std::cout << "Error: Could not open file" << std::endl;
            return;
        }
        
        if (!show_line_numbers) {
            std::cout << file.rdbuf();
            return;
        }
        
        // First pass: count total lines to determine width
        std::string line;
        int total_lines = 0;
        std::streampos start_pos = file.tellg();
        
        while (std::getline(file, line)) {
            total_lines++;
        }
        
        // Reset file position
        file.clear();
        file.seekg(start_pos);
        
        // Determine width for line numbers
        int width = count_digits(total_lines);
        
        // Second pass: print with line numbers
        int line_number = 1;
        while (std::getline(file, line)) {
            std::cout << std::setw(width) << line_number << ": " << line << std::endl;
            line_number++;
        }
    }
    
    void print_file_content(const std::vector<fs::path>& visible_files, const std::string& root_name, const fs::path& base_dir) const {
        if (visible_files.empty()) {
            std::cout << std::endl << "No matching directories or files!" << std::endl;
            return;
        }
        
        // Sort files
        std::vector<fs::path> sorted_files = visible_files;
        std::sort(sorted_files.begin(), sorted_files.end());
        
        // Print file contents
        for (const auto& file_path : sorted_files) {
            if (is_binary(file_path)) {
                // Skip binary files, don't show content
                continue;
            }
            
            fs::path relative_path = fs::relative(file_path, base_dir);
            CommentStyle style = get_comment_style(file_path);
            
            std::cout << std::endl;
            
            if (style.has_comments && !style.single_line.empty()) {
                // Use single-line comments
                std::cout << style.single_line << " ========================================================" << std::endl;
                std::cout << style.single_line << "  File: " << root_name << "/" << relative_path.string() << std::endl;
                std::cout << style.single_line << "  <content> ----------------------------------------------" << std::endl;
            } else {
                // Fallback to original format for files without comments
                std::cout << "===================================" << std::endl;
                std::cout << "File: " << root_name << "/" << relative_path.string() << std::endl;
                std::cout << "<content> -------------------------" << std::endl;
            }
            
            print_file_content_with_lines(file_path);
            
            if (style.has_comments && !style.single_line.empty()) {
                std::cout << style.single_line << "  </content> ----------------------------------------------" << std::endl;
            } else {
                std::cout << "</content> ------------------------" << std::endl;
            }
            std::cout << std::endl;
        }
    }

    // Helper method to check if a directory contains any matching files/subdirectories
    bool directory_contains_matches(const fs::path& dir) const {
        if (!fs::exists(dir) || !fs::is_directory(dir)) {
            return false;
        }
        
        try {
            for (const auto& entry : fs::directory_iterator(dir)) {
                std::string filename = entry.path().filename().string();
                
                // Skip hidden files
                if (filename[0] == '.') {
                    continue;
                }
                
                // Check if this item matches the patterns
                if (matches_patterns(entry.path())) {
                    return true;
                }
                
                // If it's a directory, recursively check its contents
                if (entry.is_directory()) {
                    if (directory_contains_matches(entry.path())) {
                        return true;
                    }
                }
            }
        } catch (const fs::filesystem_error& e) {
            // If we can't read the directory, assume it might contain matches
            return true;
        }
        
        return false;
    }
    
    void print_single_file(const fs::path& file_path) const {
        if (!fs::exists(file_path) || !fs::is_regular_file(file_path)) {
            std::cout << "Error: File does not exist or is not a regular file." << std::endl;
            return;
        }
        
        if (is_binary(file_path)) {
            std::cout << "The file " << file_path << " is binary. Content not displayed." << std::endl;
            return;
        }
        
        fs::path parent_dir = file_path.parent_path();
        std::string root_name = parent_dir.filename().string();
        std::string file_name = file_path.filename().string();
        CommentStyle style = get_comment_style(file_path);
        
        if (style.has_comments && !style.single_line.empty()) {
            // Use single-line comments
            std::cout << style.single_line << " ========================================================" << std::endl;
            std::cout << style.single_line << "  File: " << root_name << "/" << file_name << std::endl;
            std::cout << style.single_line << "  <content> ----------------------------------------------" << std::endl;
        } else {
            // Fallback to original format
            std::cout << "===================================" << std::endl;
            std::cout << "File: " << root_name << "/" << file_name << std::endl;
            std::cout << "<content> -------------------------" << std::endl;
        }
        
        print_file_content_with_lines(file_path);
        
        if (style.has_comments && !style.single_line.empty()) {
            std::cout << style.single_line << "  </content> ----------------------------------------------" << std::endl;
        } else {
            std::cout << "</content> ------------------------" << std::endl;
        }
    }
    
    void print_unknown_extensions_warning() const {
        if (!unknown_extensions.empty()) {
            std::cerr << std::endl << "Warning: Unknown file extensions encountered (no comment style defined):" << std::endl;
            for (const auto& ext : unknown_extensions) {
                std::cerr << "  " << ext << std::endl;
            }
            std::cerr << "These files will use the default format without comment-style headers." << std::endl;
            std::cerr << std::endl;
        }
    }
    
public:
    void add_pattern_filter(const std::string& pattern, bool is_include) {
        pattern_filters.push_back({pattern, is_include});
    }
    
    void set_show_dir_only(bool value) {
        show_dir_only = value;
    }
    
    void set_show_line_numbers(bool value) {
        show_line_numbers = value;
    }
    
    void process_target(const std::string& target) {
        if (target.empty()) {
            // Current directory
            base_directory = fs::current_path();
            std::string root_name = base_directory.filename().string();
            
            std::cout << root_name << std::endl;
            
            std::vector<fs::path> visible_files;
            print_tree(base_directory, "", visible_files);
            
            if (!show_dir_only) {
                print_file_content(visible_files, root_name, base_directory);
            }
            
            // Print warning about unknown extensions at the end
            print_unknown_extensions_warning();
        } else {
            fs::path target_path(target);
            
            // Make the target path absolute first to avoid issues with relative paths
            fs::path absolute_target_path;
            try {
                absolute_target_path = fs::absolute(target_path);
            } catch (const fs::filesystem_error& e) {
                std::cout << "Error: Cannot resolve path '" << target << "': " << e.what() << std::endl;
                return;
            }
            
            if (fs::is_directory(absolute_target_path)) {
                base_directory = absolute_target_path;
                std::string root_name = base_directory.filename().string();
                
                std::cout << root_name << std::endl;
                
                std::vector<fs::path> visible_files;
                print_tree(base_directory, "", visible_files);
                
                if (!show_dir_only) {
                    print_file_content(visible_files, root_name, base_directory);
                }
                
                // Print warning about unknown extensions at the end
                print_unknown_extensions_warning();
            } else if (fs::is_regular_file(absolute_target_path)) {
                // For files, get the parent directory safely
                fs::path parent_path = absolute_target_path.parent_path();
                if (parent_path.empty()) {
                    // If parent is empty, use current directory
                    base_directory = fs::current_path();
                } else {
                    base_directory = parent_path;
                }
                
                if (matches_patterns(absolute_target_path)) {
                    print_single_file(absolute_target_path);
                    // Print warning about unknown extensions at the end
                    print_unknown_extensions_warning();
                } else {
                    std::cout << "No matching directories or files!" << std::endl;
                }
            } else {
                std::cout << "Error: Target does not exist or is not accessible." << std::endl;
            }
        }
    }

    static void print_usage(const char* program_name) {
        std::cout << "Usage: " << program_name << " [-d] [-n] [-e pattern] [-v pattern] [filename|directory]" << std::endl;
        std::cout << "  -d : only show the directory structure" << std::endl;
        std::cout << "  -n : show line numbers in file content" << std::endl;
        std::cout << "  -e pattern : only include files/directories matching pattern (regex)" << std::endl;
        std::cout << "  -v pattern : exclude files/directories matching pattern (regex)" << std::endl;
        std::cout << "  Multiple -e and -v options can be used and are applied in order" << std::endl;
        std::cout << "  Patterns match against the full relative path from the base directory" << std::endl;
        std::cout << "  filename or directory : show output from given directory, or if a file, only the file content" << std::endl;
        std::cout << "  If no arguments are provided, it will show both structure and content for the current directory" << std::endl;
        std::cout << std::endl;
        std::cout << "Examples:" << std::endl;
        std::cout << "  " << program_name << " -v grpc -e \"\\.ex$\"       # Exclude paths containing 'grpc', include only .ex files" << std::endl;
        std::cout << "  " << program_name << " -e \"src|include\"          # Include only paths matching 'src' or 'include'" << std::endl;
        std::cout << "  " << program_name << " -v \"\\.o$\" -v \"\\.so$\"     # Exclude .o and .so files" << std::endl;
        std::cout << "  " << program_name << " -n myfile.cpp             # Show myfile.cpp with line numbers" << std::endl;
        std::cout << "  " << program_name << " -e \"knowbr_elixir_web/grpc/services\"  # Include only paths under grpc/services" << std::endl;
    }
};

int main(int argc, char* argv[]) {
    TreePrinter printer;
    std::string target;
    
    int opt;
    while ((opt = getopt(argc, argv, "dne:v:")) != -1) {
        switch (opt) {
            case 'd':
                printer.set_show_dir_only(true);
                break;
            case 'n':
                printer.set_show_line_numbers(true);
                break;
            case 'e':
                printer.add_pattern_filter(optarg, true);  // include pattern
                break;
            case 'v':
                printer.add_pattern_filter(optarg, false); // exclude pattern
                break;
            default:
                TreePrinter::print_usage(argv[0]);
                return 1;
        }
    }
    
    // Get remaining argument (target)
    if (optind < argc) {
        target = argv[optind];
    }
    
    printer.process_target(target);
    
    return 0;
}
